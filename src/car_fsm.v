// =============================================================================
// car_fsm.v —— 整车状态机（起跑 / 循迹 / 丢线保持 / 原地找线 / 停车）
// -----------------------------------------------------------------------------
// 状态流转：
//
//   IDLE --(连续压线 START_MS)--> RUN --(丢线)--> LOST --(保持超时)--> SEARCH
//                              |                 |                   |
//                              |<--(重新压线)----+-------------------+
//                              |                                     |
//                              +--(障碍)-------------------------+   |
//                              |                                 |   |
//   AVOID_ROUTE_EN=1: RUN --障碍--> PROBE（弧线侧绕五段）--------+   |
//                              |   OUT --> ALIGN --> PASS -->         |
//                              |   TURN_IN --> REJOIN --> RUN         |
//                              |                                      |
//   AVOID_ROUTE_EN=0: RUN --障碍--> BACK --> TURN --> PROBE（老三段） |
//                    (后退)  (原地转)  (试探前进)                     |
//                              |             (还有障碍 & 未超次数)---+
//                              |                     (无障碍) --> RUN
//                              |                (次数用尽) --> STOP
//                              +<--找线超时(SEARCH_FAIL_TO_IDLE=1)---+
//
// 【侧绕为什么用弧线】细则 4.3.2 禁止"以大转弯形式绕开障碍"，而倒车+原地
// 掉头恰恰是车尾横向摆幅最大的动作（车尾可扫出约 17 cm）。侧绕模式把整个
// 动作换成五段两轮正转的差速圆弧，全程不出现反转轮，车体沿弧线平移让开方块。
//
// 【为什么要有 LOST 这一级】track_line 的 lost 会在线抖动/短暂离线的瞬间置位，
// 立刻进找线会让车原地抽搐。先保持最后一刻的转向 HOLD_MS，多数情况下线就回来了。
//
// 【找线方向】按最后一次看到线的位置决定（pos>0 说明线在右边 → 向右原地转），
// 比固定"往左找"稍好；且比左右来回扫更简单（不需要额外状态）。
//
// 【方向死区】【重要】TB6612 在 IN1/IN2 同时翻转时会短暂短路刹车，实测会有电流尖峰。
// 因此方向改变时先拉低 PWM（DIR_DEAD_MS），再换相；换相后也先低占空比。
// =============================================================================
`timescale 1ns/1ns

module car_fsm #(
    parameter integer CLK_FREQ      = 24_000_000,
    parameter integer START_MS      = 2000,   // 连续压线多久后起跑（留时间松手）
    parameter integer START_REQUIRE_LINE = 1, // 1 = 必须压线才起跑（安全锁）
    parameter integer LOST_HOLD_MS  = 300,    // 丢线先保持多久
    parameter integer SEARCH_MS     = 1500,   // 原地找线最长多久
    parameter integer SEARCH_DUTY   = 500,    // 找线时的占空比
    parameter integer SEARCH_FAIL_TO_IDLE = 1, // 找线超时后：1=回 IDLE 等重新压线，0=永久停车
    parameter integer DIR_DEAD_MS   = 10,     // 方向切换死区
    parameter integer TURN_MS       = 700,    // 交通牌强制转向的最长时长（不是固定时长）
    parameter integer TURN_DUTY     = 700,    // 强制转向时的占空比
    // 闭环转向：菱形锐角需要的转角比直角大，而定长转向时间一到就把车交回
    // PID，此时车头还差一截，直接丢线滑走。改成边转边看线：连续压回线就
    // 提前收工，TURN_MS 只当上限。
    parameter integer TURN_MIN_MS   = 250,    // 至少先转这么久，防止刚起步还压着线就立刻结束
    parameter integer TURN_LINE_MS  = 20,     // 连续压线多少 ms 才算"线已经找回来"
    parameter integer TURN_WAIT_FOR_CORNER = 0, // 1: 先存方向，宽黑后丢线才执行
    parameter integer TURN_REQUEST_MS = 12000,  // 转向牌等待岔口的上限
    // ---- 避障（BACK → TURN → PROBE 三段）----
    parameter integer AVOID_EN    = 1,      // 1 = 遇障碍执行避障；0 = 旧行为（原地停，障碍消失即走）
    parameter integer AVOID_BACK_MS = 400,  // 后退时长
    parameter integer AVOID_BACK_DUTY = 500,// 后退占空比
    parameter integer AVOID_TURN_MS = 600,  // 出线转向和摆正的原地转时长
    parameter integer AVOID_TURN_DUTY = 600,// 原地转占空比
    parameter integer AVOID_PROBE_MS = 400, // 试探前进时长
    parameter integer AVOID_PROBE_DUTY = 450,// 试探前进占空比
    // 进 PROBE 后的静默观察窗：这段时间内不判 obstacle。
    // 为什么必须有：从 TURN 转进 PROBE 时障碍通常还在正前方（车还没动），
    // 若第一拍就判 obstacle，"试探前进"这一步只跑 1 ms 就被打回 BACK，
    // 3 轮配额瞬间耗尽 —— 避障退化成"原地左右各抖 600 ms 再停车"。
    parameter integer AVOID_PROBE_SETTLE_MS = 100,
    parameter integer AVOID_TRIES = 3,      // 最多连续尝试次数，用尽则停车等待
    parameter integer AVOID_ROUTE_EN = 0,  // 启用侧绕并定向回线；0 保留三段试探
    parameter integer AVOID_FIXED_RIGHT = 0, // 侧绕时 1=固定右侧，0=按最后线位选侧
    parameter integer AVOID_PASS_MS = 900, // 车头摆正后沿障碍侧边直行
    parameter integer AVOID_REJOIN_MS = 1200,
    parameter integer AVOID_REJOIN_DUTY = 640,   // BY_REJOIN 外侧快轮
    // ---- 弧线绕障（AVOID_ROUTE_EN=1 时使用）----
    // 每一段都是"两轮都正转、外侧快内侧慢"的圆弧，靠差速而非原地转向改变航向，
    // 因此车头/车尾的横向摆幅远小于原地转，符合细则"不能大转弯"的要求。
    // 占空比成对给出：OUT 段把车从线中心推到障碍侧边，ALIGN 段把航向摆正，
    // TURN_IN 段斜切回线，REJOIN 段用较小的差速把残余偏角慢慢找回来。
    parameter integer AVOID_OUT_DUTY     = 860,  // BY_OUT 外侧轮
    parameter integer AVOID_OUT_IN_DUTY  = 380,  // BY_OUT 内侧轮
    parameter integer AVOID_ALIGN_DUTY   = 840,  // BY_ALIGN 外侧快轮（反向弧，摆正航向）
    parameter integer AVOID_ALIGN_IN_DUTY= 400,  // BY_ALIGN 内侧慢轮
    parameter integer AVOID_PASS_DUTY    = 620,  // BY_PASS 直线超越，两轮同速
    parameter integer AVOID_TURN_IN_DUTY = 860,  // BY_TURN_IN 外侧快轮（反向弧切回线）
    parameter integer AVOID_TURN_IN_IN_DUTY = 420, // BY_TURN_IN 内侧慢轮
    parameter integer AVOID_REJOIN_IN_DUTY  = 430, // BY_REJOIN 内侧慢轮
    // 【弧线段改为里程闭环】原来 OUT/ALIGN/PASS 都是按毫秒截断的，而同样的
    // 毫秒数在不同车速下转过的角度完全不同 —— 电池电压、地面摩擦、载重一变，
    // 弧就画歪，轻则回不了线，重则直接蹭上方块。改成数编码器后，两轮计数
    // **差**只由航向变化决定，与车速无关，转角就稳定了。
    //   转角(度) = diff_cnt * 轮周长 / (每轮圈计数 * 轮距) * 180/pi
    //   默认 20 线编码器四倍频 = 80 计数/电机圈，减速 1:48 -> 3840 计数/轮圈
    //   轮周长 23.2 cm、轮距 16.0 cm 时：60 度 = 2774 个计数差
    // 真要改标定，只改 ENC_CNT_PER_REV / WHEEL_CIRC_MM / WHEEL_BASE_MM 三个数。
    parameter integer ENC_CNT_PER_REV  = 3840, // 每轮圈计数（四倍频 × 减速比）
    parameter integer WHEEL_CIRC_MM    = 232,  // 轮周长, mm
    parameter integer WHEEL_BASE_MM    = 160,  // 轮距, mm
    parameter integer AVOID_ARC_DEG    = 60,   // 单弧目标转角（度）
    parameter integer AVOID_PASS_MM    = 200,  // BY_PASS 直线超越距离, mm
    // 下面两条 *_MS 已降级为**超时上限**：编码器不出脉冲时（没装/线松）仍能
    // 走完动作，不会卡死在半路。正常有编码器时提前里程到了就切换。
    parameter integer AVOID_OUT_MS      = 2500, // 外摆弧超时上限
    parameter integer AVOID_ALIGN_MS    = 2500, // 摆正弧超时上限
    parameter integer AVOID_LINE_MS = 20,  // 回线时黑线需稳定出现
    parameter integer AVOID_BLOCK_MS = 250,// 前方受阻先停，再等超声更新
    // ---- 拐角兜底（没有 K230 / 没识别到转向牌时怎么走）----
    // 1 = 判到"直角/菱形拐角"而没有任何转向牌事件时，**方位未知**才向左转；
    // 0 = 退回旧行为（按最后看到线的方位转，线在左就左转、在右就右转）。
    // 现在优先按"入弯前最后明确看到的线方位"决定方向（corner_side_valid），
    // 本参数只在**从未看到过明确方位**（刚起步就压上拐角）时兜底。
    parameter integer DEFAULT_TURN_LEFT = 1,
    // 宽黑（wide）出现后多久内仍算"拐角"。0 = 完全不做拐角判断。
    parameter integer CORNER_WIDE_MS = 500,

    // 转向指示（串口 S= / OLED 左转右转格）保持多久。
    // 不保持的话，一次转弯只有 1~2 ms 的脉冲，OLED 每 100 ms 才采一次样，
    // 基本抓不到；但一直保持又会让直道上也显示"正在左转"，反而看不懂。
    // 1500 ms 覆盖整个 S_SEARCH（SEARCH_MS=1500），之后自动熄灭。
    parameter integer TURN_DIR_HOLD_MS = 1500,
    parameter integer AVOID_TURN_IN_MS = AVOID_TURN_MS // 绕过障碍后朝黑线原地转的时长
) (
    input  wire              clk,
    input  wire              rst_n,
    // 感知
    input  wire              on_line,
    input  wire              lost,
    input  wire              obstacle,
    input  wire              wide,          // 1 = 当前宽黑（拐角/影子），拐角兜底用
    input  wire signed [4:0] pos,
input  wire [2:0]        dir_evt,        // 交通牌：0=无 1=左 2=右 3=直，单周期脉冲
    // 闭环输出
    input  wire [10:0]       pid_l,
    input  wire [10:0]       pid_r,
    // 编码器里程（弧线绕障的闭环量，各 1 clk 脉冲）
    input  wire              enc_l_step,
    input  wire              enc_r_step,
    // 执行
    output wire              en,              // 1 = 电机使能（同时接 TB6612 STBY）
    output reg               dir_l,           // 1 = 正转（车前进）
    output reg               dir_r,
    output reg  [10:0]       duty_l,
    output reg  [10:0]       duty_r,
    output reg  [2:0]        state,           // 观察用
    output reg  [1:0]        turn_dir         // 最近一次转向方向：0=无 1=左 2=右
);

    // 5/6/7 三个编码正好空着，避障直接占用，M= 字段（两位十进制）无需扩位。
    localparam [2:0] S_IDLE       = 3'd0,
                     S_RUN        = 3'd1,
                     S_LOST       = 3'd2,
                     S_SEARCH     = 3'd3,
                     S_STOP       = 3'd4,
                     S_AVOID_BACK = 3'd5,
                     S_AVOID_TURN = 3'd6,
                     S_AVOID_PROBE= 3'd7;

    localparam integer MS_DIV     = CLK_FREQ / 1000;
    localparam integer DEAD_CYC   = MS_DIV * DIR_DEAD_MS;

    // ---------------- 1 ms 节拍 ----------------
    reg [15:0] ms_div;
    wire       ms_tick = (ms_div >= MS_DIV - 1);

    always @(posedge clk or negedge rst_n)
        if (!rst_n)      ms_div <= 16'd0;
        else if (ms_tick) ms_div <= 16'd0;
        else             ms_div <= ms_div + 16'd1;

    reg [15:0] ms_cnt;

    // ---------------- 状态 ----------------
    reg        final_stop;          // 找线超时后的永久停车（只能靠复位解除）
    reg        last_pos_neg;        // 最后看到线时 pos<0（线在左）
    // 拐角方向记忆：只记"明确方位"（pos != 0），pos==0 视为没有信息，不覆盖。
    // 为什么不能直接用 last_pos_neg：它每个压线毫秒都写，直道正中 pos=0 会
    // 被写成"右"，拐角兜底就会朝反方向转（闭环仿真 90° 拐角 21/126 失败）。
    reg        corner_side;         // 1 = 线在左
    reg        corner_side_valid;   // 1 = 至少明确看到过一次方位

    // ---------------- 交通牌强制转向 ----------------
    reg        turning;             // 1 = 正在按交通牌转向
    reg [15:0] turn_cnt;            // 转向剩余 ms
    reg [15:0] turn_line_cnt;       // 转向期间连续压线的毫秒数（闭环提前结束用）
    reg        turn_left;           // 1 = 左转（左轮后退、右轮前进）
    reg        turn_req;            // 已收到转向请求
    reg [15:0] turn_request_left;

    // ---------------- 拐角兜底（没有 K230 时的默认左转）----------------
    // 直角/菱形拐角在八路阵列上表现为"先宽黑、后全丢线"。宽黑出现后
    // CORNER_WIDE_MS 内丢线，就认为这是拐角而不是普通跑偏，此时若没有
    // 转向牌事件（K230 没装/没识别到），就按 corner_side 决定往哪边转。
    //
    // 为什么不再"一律左转"：闭环运动学仿真（8 路探头 + track_line 宽黑判据 +
    // track_pid + 差速车体）在 90° 拐角上扫了 126 组入弯位姿（横向偏移 ±30 mm、
    // 车头偏角 ±3°、90/75/60°、左右各一次）：一律左转 21 组冲出赛道；
    // 按入弯前最后看到的线方位转 0 组失败。机理是宽黑那 200 ms 里 pos 被冻结，
    // 车按过期位置直冲，等真的丢线时已经偏出 40~50 mm，方向猜错就救不回来。
    // DEFAULT_TURN_LEFT 保留为"从未看到过明确方位"时的兜底（菱形左转两次的场景
    // 正常情况下入弯前都能看到线在哪边）。
    // 不做这个区分的话，正常右弯跑偏丢线也会被强制左转，车会往反方向找线。
    reg  [15:0] corner_cnt;         // 距离上次宽黑还有多少 ms
    reg  [15:0] turn_dir_cnt;       // 转向指示还要亮多久（0 = 灭）
    wire turn_allowed = (TURN_WAIT_FOR_CORNER == 0) ||
                        (lost && !wide && (corner_cnt != 0) && (turn_request_left != 0));

    // ---------------- 方向死区 ----------------
    reg        dead;
    // 死区计时必须比 MS_DIV 宽：DEAD_CYC = MS_DIV * DIR_DEAD_MS，
    // 24 MHz + DIR_DEAD_MS=10 时是 240000，16 位放不下（上限 65535）。
    // 宽度不够的后果不是"死区变短"，而是 dead_cnt 永远追不上 DEAD_CYC-1，
    // dead 一旦置位就再也不清 → en 恒 0、duty 恒 0，车再也不动。
    // 测试台用 DIR_DEAD_MS=1（24000，刚好放得下）所以测不出这个错。
    reg [31:0] dead_cnt;
    reg        dir_l_des, dir_r_des;

    // ---------------- 避障 ----------------
    reg [3:0]  avoid_tries;         // 本次障碍已尝试几轮
    reg        avoid_left;          // 1 = 这次往左绕（按最后看到线的方位反着走）
    wire       avoid_start_left = !last_pos_neg && (AVOID_ROUTE_EN == 0 || AVOID_FIXED_RIGHT == 0);

    localparam [2:0] BY_OUT = 3'd0, BY_ALIGN = 3'd1, BY_PASS = 3'd2,
                     BY_TURN_IN = 3'd3, BY_REJOIN = 3'd4;
    reg [2:0] bypass_step;
    reg bypass_left_line;
    reg [15:0] bypass_line_cnt, bypass_block_cnt;
    reg [15:0] bypass_turn_in_cnt;   // TURN_IN 期间连续看到线的毫秒数

    // ---------------- 弧线里程闭环计数器 ----------------
    // 为什么数里程而不是数毫秒：同一段毫秒数在不同车速下转过的角度完全不同。
    // 两轮编码器计数**差**只由航向变化决定（与车速无关）：
    //   Δ航向 = (d_r - d_l) / 轮距，d = 计数 × 轮周长 / 每圈计数
    // 所以数够固定的计数差，转角就是固定的，电池掉压、地面变滑都不影响。
    localparam integer ARC_CNT_PER_RAD  = (ENC_CNT_PER_REV * WHEEL_BASE_MM) / WHEEL_CIRC_MM;
    localparam integer ARC_MRAD         = (AVOID_ARC_DEG * 31416 + 900) / 1800;  // 毫弧度
    localparam integer ARC_DIFF_TARGET  = (ARC_MRAD * ARC_CNT_PER_RAD) / 1000;
    localparam integer PASS_SUM_TARGET  = (AVOID_PASS_MM * ENC_CNT_PER_REV) / WHEEL_CIRC_MM;

    reg [31:0] arc_cnt_l, arc_cnt_r;   // 本段内两轮各自累计脉冲
    reg [2:0]  arc_step_d, arc_state_d;// 上一拍的段号/状态，用来切段清零
    wire       arc_seg_new  = (state != arc_state_d) || (bypass_step != arc_step_d);
    wire [31:0] arc_diff    = (arc_cnt_l > arc_cnt_r) ? (arc_cnt_l - arc_cnt_r)
                                                      : (arc_cnt_r - arc_cnt_l);
    wire [31:0] arc_sum     = arc_cnt_l + arc_cnt_r;
    wire        arc_diff_done = (arc_diff >= ARC_DIFF_TARGET);
    wire        arc_sum_done  = (arc_sum  >= (PASS_SUM_TARGET * 2));
    // 【入口分流】AVOID_EN=0 → 停车等待；AVOID_ROUTE_EN=1 → 直接进弧线绕行；
    // 其余 → 老的三段（后退 → 原地转 → 试探）。
    // 必须让侧绕跳过 BACK/TURN：那两段正是细则 4.3.2 禁止的"倒车 + 大转弯"。
    wire [2:0] avoid_entry_state = (AVOID_EN == 0)       ? S_STOP :
                                   (AVOID_ROUTE_EN != 0) ? S_AVOID_PROBE :
                                                           S_AVOID_BACK;
    wire avoid_backing = (state == S_AVOID_BACK);
    wire avoid_turning_out = (state == S_AVOID_TURN);
    wire avoid_active = avoid_backing || avoid_turning_out || (state == S_AVOID_PROBE);
    wire bypass_active = (AVOID_ROUTE_EN != 0) && (state == S_AVOID_PROBE);
    // 【弧线绕障】绕行全程两轮都正转，只靠左右差速画弧：
    //   外侧轮快、内侧轮慢 → 车沿圆弧向外侧平移，没有"倒车 + 原地掉头"。
    // 为什么不用原地转：细则 4.3.2 明文禁止"以大转弯的形式绕开障碍"，
    // 而原地转虽然转弯半径≈0，车头/车尾摆幅却最大（车尾扫出约 17 cm），
    // 恰好是 10 cm 立方体旁边最容易蹭上去的动作。
    // 【绕行期间不看超声】弧线绕障的整条轨迹是预先按几何算好的，方块本来就
    // 必然处在 25 cm 阈值以内（否则根本不会触发绕行）。若在这里继续用
    // obstacle 判"受阻"，车会在 BY_OUT/BY_PASS 途中被自己的绕行对象冻住。
    // 安全性改由三段兜底保证：BY_TURN_IN 扫线上限、BY_REJOIN 超时进 S_STOP。
    wire bypass_forward = (bypass_step == BY_PASS || bypass_step == BY_REJOIN);

    // ---------------- 弧线里程计数 ----------------
    // 每进一个新段（BY_OUT/ALIGN/PASS）清零重来；只在真的驱动时计数，
    // 换相死区/未就绪那几拍编码器可能还在滑行，不该算进本段里程。
    wire bypass_blocked = 1'b0;
    wire line_visible = on_line && !lost && !wide;   // 真的压在线上（宽黑不算）
    wire bypass_has_line = line_visible;

    // 转向符号：avoid_left=1 表示从障碍左侧（线的左边）绕过去。
    // 弧线绕行用外侧轮/内侧轮占空比差实现，"左绕"= 右轮快、左轮慢。
    // 老的三段试探仍用原地转（avoid_turning_out），这里两者并存互不影响。
    // 【只有旧三段用原地转】AVOID_ROUTE_EN=1 的侧绕已全部改为两轮正转的差速弧，
    // 弧线段（ALIGN / TURN_IN）不再是"一正一反原地掉头"，所以不能再走 pivot 通路。
    wire avoid_pivot = avoid_turning_out;
    wire avoid_turn_left = avoid_left;
    wire avoid_forward = (state == S_AVOID_PROBE) && !avoid_pivot;

    // 每段的 (外侧快轮, 内侧慢轮) 占空比。BY_PASS 单独取同速值。
    wire [10:0] bypass_outer = (bypass_step == BY_ALIGN)   ? AVOID_ALIGN_DUTY[10:0] :
                               (bypass_step == BY_TURN_IN) ? AVOID_TURN_IN_DUTY[10:0] :
                               (bypass_step == BY_REJOIN)  ? AVOID_REJOIN_DUTY[10:0] :
                                                             AVOID_OUT_DUTY[10:0];
    wire [10:0] bypass_inner = (bypass_step == BY_ALIGN)   ? AVOID_ALIGN_IN_DUTY[10:0] :
                               (bypass_step == BY_TURN_IN) ? AVOID_TURN_IN_IN_DUTY[10:0] :
                               (bypass_step == BY_REJOIN)  ? AVOID_REJOIN_IN_DUTY[10:0] :
                                                             AVOID_OUT_IN_DUTY[10:0];

    // 【弧向】哪几段往哪边打弯：
    //   BY_OUT   朝绕行侧偏（左绕就左转）—— 把车推到障碍侧边；
    //   BY_ALIGN 反打回来，把航向摆正，车沿障碍侧边平行前进；
    //   BY_PASS  两轮同速直线超越障碍；
    //   BY_TURN_IN / BY_REJOIN 继续反打，斜切回原线路。
    // 差速方向：两轮都正转时，左轮慢 = 车头左偏，右轮慢 = 车头右偏。
    wire bypass_straight = (bypass_step == BY_PASS);
    wire bypass_arc_left = (bypass_step == BY_OUT) ? avoid_left : !avoid_left;

    // 【必须区分侧绕与老三段】bypass_step 只在 bypass_active 时有效；AVOID_ROUTE_EN=0
    // 时它恒为 BY_OUT，若直接拿它选弧线占空比，老三段的"试探前进"会跑成 860/380，
    // 与 AVOID_PROBE_DUTY 不等 → avoid_drive 永不成立 → en 不置位 → 状态机卡死。
    wire [10:0] avoid_duty_l = avoid_backing ? AVOID_BACK_DUTY[10:0] :
                               avoid_pivot   ? AVOID_TURN_DUTY[10:0] :
                               !bypass_active ? AVOID_PROBE_DUTY[10:0] :
                               bypass_straight ? AVOID_PASS_DUTY[10:0] :
                               bypass_arc_left ? bypass_inner : bypass_outer;
    wire [10:0] avoid_duty_r = avoid_backing ? AVOID_BACK_DUTY[10:0] :
                               avoid_pivot   ? AVOID_TURN_DUTY[10:0] :
                               !bypass_active ? AVOID_PROBE_DUTY[10:0] :
                               bypass_straight ? AVOID_PASS_DUTY[10:0] :
                               bypass_arc_left ? bypass_outer : bypass_inner;

    // 弧线段两轮都正转；后退段两轮都反转；只有老的三段试探里的原地转才一正一反。
    wire avoid_dir_l = avoid_backing ? 1'b0 : avoid_pivot ? !avoid_turn_left : 1'b1;
    wire avoid_dir_r = avoid_backing ? 1'b0 : avoid_pivot ?  avoid_turn_left : 1'b1;

    // 每段只在死区结束、两轮方向和占空比就绪后计时。
    wire avoid_dirs_ready = !dead && !bypass_blocked &&
                            (dir_l == avoid_dir_l) && (dir_r == avoid_dir_r);
    wire avoid_drive = avoid_dirs_ready && (duty_l == avoid_duty_l) && (duty_r == avoid_duty_r);

    wire en_run = (state == S_RUN)   || (state == S_LOST)     || (state == S_SEARCH)
               || avoid_active;
    assign en = en_run && !dead && (!avoid_active || avoid_drive);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            arc_cnt_l  <= 32'd0;
            arc_cnt_r  <= 32'd0;
            arc_step_d <= 3'd0;
            arc_state_d<= 3'd0;
        end else if (arc_seg_new) begin
            arc_cnt_l  <= 32'd0;
            arc_cnt_r  <= 32'd0;
            arc_step_d <= bypass_step;
            arc_state_d<= state;
        end else if (bypass_active && avoid_drive) begin
            if (enc_l_step) arc_cnt_l <= arc_cnt_l + 32'd1;
            if (enc_r_step) arc_cnt_r <= arc_cnt_r + 32'd1;
        end


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            ms_cnt      <= 16'd0;
            final_stop  <= 1'b0;
            last_pos_neg <= 1'b0;
            corner_side  <= 1'b1;
            corner_side_valid <= 1'b0;
            dir_l       <= 1'b1;
            dir_r       <= 1'b1;
            dir_l_des   <= 1'b1;
            dir_r_des   <= 1'b1;
            duty_l      <= 11'd0;
            duty_r      <= 11'd0;
            dead        <= 1'b0;
            dead_cnt    <= 32'd0;
            turning     <= 1'b0;
            turn_cnt    <= 16'd0;
            turn_line_cnt <= 16'd0;
            turn_left   <= 1'b0;
            turn_req    <= 1'b0;
            turn_request_left <= 16'd0;
            avoid_tries <= 4'd0;
            avoid_left  <= 1'b0;
            bypass_step <= BY_OUT;
            bypass_left_line <= 1'b0;
            bypass_line_cnt <= 16'd0;
            bypass_block_cnt <= 16'd0;
            bypass_turn_in_cnt <= 16'd0;
            corner_cnt   <= 16'd0;
            turn_dir     <= 2'd0;
            turn_dir_cnt <= 16'd0;
        end else begin
            // ---- 记住线的方位 ----
            if (on_line && !lost) begin
                last_pos_neg <= pos[4];
                // 拐角方向记忆只采信"明确偏左/偏右"，居中（pos==0）不覆盖已有记忆。
                // 直接用 last_pos_neg 会在直道正中把它写成"右"，拐角就朝反方向转。
                // 限定 S_RUN：拐角只在这一态被识别（见 corner_cnt 武装条件），
                // 而 S_SEARCH/S_AVOID 期间车体是横着扫过线的，方位没有意义。
                if ((state == S_RUN) && (pos != 5'sd0)) begin
                    corner_side       <= pos[4];
                    corner_side_valid <= 1'b1;
                end
            end

            // ---- 方向死区计数 ----
            if (dead) begin
                if (dead_cnt >= DEAD_CYC - 1) begin
                    dead      <= 1'b0;
                    dead_cnt  <= 32'd0;
                    dir_l     <= dir_l_des;
                    dir_r     <= dir_r_des;
                end else begin
                    dead_cnt <= dead_cnt + 32'd1;
                end
            end else if ((dir_l_des != dir_l) || (dir_r_des != dir_r)) begin
                dead     <= 1'b1;
                dead_cnt <= 32'd0;
                duty_l   <= 11'd0;      // 换相前先断电
                duty_r   <= 11'd0;
            end

            // ---- 交通牌事件锁存 ----
            // dir_evt 是单周期脉冲，而主状态机 1 ms 才走一步，直接在里面判会漏。
            // 前视联调模式在循迹确认岔口前只锁存方向，超时自动丢弃。
            if ((dir_evt == 3'd1 || dir_evt == 3'd2) &&
                ((TURN_WAIT_FOR_CORNER == 0) || !turning)) begin
                turn_req  <= 1'b1;
                turn_left <= dir_evt == 3'd1;
                turn_request_left <= TURN_REQUEST_MS[15:0];
                if (TURN_WAIT_FOR_CORNER == 0) begin
                    turn_dir <= (dir_evt == 3'd1) ? 2'd1 : 2'd2;
                    turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                end
            end else if (dir_evt == 3'd3) begin
                turn_req  <= 1'b0;
                turn_request_left <= 16'd0;
                turning   <= 1'b0;
                turn_cnt  <= 16'd0;
                turn_dir  <= 2'd0;      // 直行牌 = 取消转向，指示也一并灭掉
                turn_dir_cnt <= 16'd0;
                corner_cnt   <= 16'd0;  // 直行牌同时清拐角记忆，避免随后误触兜底
            end

            // ---- 主状态机（1 ms 步进）----
            if (ms_tick) begin
                if (avoid_active) begin
                    dir_l_des <= avoid_dir_l;
                    dir_r_des <= avoid_dir_r;
                    duty_l <= avoid_dirs_ready ? avoid_duty_l : 11'd0;
                    duty_r <= avoid_dirs_ready ? avoid_duty_r : 11'd0;
                end
                if (!bypass_active) begin
                    bypass_step <= BY_OUT;
                    bypass_left_line <= 1'b0;
                    bypass_line_cnt <= 16'd0;
                    bypass_block_cnt <= 16'd0;
                end
                if ((TURN_WAIT_FOR_CORNER != 0) && turn_req && dir_evt == 3'd0) begin
                    if (turn_request_left != 0) turn_request_left <= turn_request_left - 16'd1;
                    if (turn_request_left <= 16'd1) turn_req <= 1'b0;
                end
                // ---- 拐角记忆 ----
                // 直角/菱形拐角会让八路同时压线（wide=1），随后整条线消失。
                // 记住"刚过拐角"这段时间，找线时才能区分"拐角"和"普通跑偏"。
                // 【必须 !turning】强制转向期间车是有意离开赛道的，车体扫过线/宽黑
                // 区域时 wide 会置位。若不加这个门控，转向结束回到找线时
                // corner_cnt 还没衰减完，拐角兜底会把刚按牌子做的转向反着执行一遍
                // （牌要求右转 → 兜底强制左转），直接违反"有牌就完全按牌走"。
                // 当前 USE_K230=0 时 turning 永远进不去，这条是接回 K230 后的保险。
                //
                // 【只能在 S_RUN 武装】只加 !turning 是不够的：交通牌在 S_LOST 里
                // 被消费时（走的是找线方向决策，不置 turning），随后 1.5 s 的原地
                // 旋转会让车体扫过赛道线，wide 被自己转出来 —— 若此时还允许武装，
                // corner_cnt 会被重新填满，下一次丢线时拐角兜底又把牌的方向反着
                // 执行（牌要求右转 → 兜底强制左转）。真正的拐角只会出现在正常
                // 循迹（S_RUN）途中，所以武装条件收紧到 state == S_RUN。
                // 倒计时不受这个门控影响，仍然每 ms 衰减。
                if ((AVOID_ROUTE_EN != 0) && (state >= S_AVOID_BACK)) begin
                    corner_cnt <= 16'd0;
                end else if (!turning && !lost && (state == S_RUN) &&
                             wide && CORNER_WIDE_MS > 0) begin
                    corner_cnt <= CORNER_WIDE_MS[15:0];
                end else if (corner_cnt != 16'd0) begin
                    corner_cnt <= corner_cnt - 16'd1;
                end

                // ---- 转向指示保持计时 ----
                // 到 0 那一拍把 turn_dir 清掉，屏上两格才不会常亮。
                if (turn_dir_cnt != 16'd0) begin
                    turn_dir_cnt <= turn_dir_cnt - 16'd1;
                    if (turn_dir_cnt == 16'd1) turn_dir <= 2'd0;
                end

                case (state)
                S_IDLE: begin
                    duty_l <= 11'd0;
                    duty_r <= 11'd0;
                    dir_l_des <= 1'b1;
                    dir_r_des <= 1'b1;
                    // 【起跑条件 / 安全锁】
                    //   START_REQUIRE_LINE=1（默认）时必须"连续压线 START_MS"才起跑，
                    //   相当于把"把车放到线上"当作钥匙。理由：电机接上以后，
                    //   旧的"上电计时到点就跑"会让车在桌面/箱子里自己窜出去；
                    //   没压线时这里会一直停着，绝不会自行启动。
                    //   =0 时退回旧行为（仅台架/专项测试用）。
                    if (START_REQUIRE_LINE != 0 && !(on_line && !lost)) begin
                        ms_cnt <= 16'd0;        // 一离线就重新计时，防止抖动蒙混起跑
                    end else if (ms_cnt >= START_MS - 1) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_RUN: begin
                    if (turning) begin
                        // ---- 交通牌强制转向 ----
                        // 期间车道线会先被甩开（本来就是有意离开），所以忽略 lost，
                        // 否则一压离线就跳 S_LOST，转向走不完。障碍仍然优先停车。
                        dir_l_des <= turn_left ? 1'b0 : 1'b1;   // 左转：左轮后退
                        dir_r_des <= turn_left ? 1'b1 : 1'b0;   //       右轮前进
                        if (!dead) begin
                            duty_l <= TURN_DUTY[10:0];
                            duty_r <= TURN_DUTY[10:0];
                        end
                        turn_line_cnt <= line_visible ? (turn_line_cnt + 16'd1) : 16'd0;
                        turn_cnt <= turn_cnt - 16'd1;
                        if (turn_cnt <= 16'd1) begin
                            turning <= 1'b0;
                            ms_cnt  <= 16'd0;
                            // 转向结束时清掉拐角记忆：这段时间里车轮扫过的
                            // 宽黑是"转向动作本身造成的"，不是赛道拐角特征。
                            corner_cnt <= 16'd0;
                        end else if ((TURN_LINE_MS > 0) &&
                                     (turn_line_cnt >= TURN_LINE_MS - 1) &&
                                     ((TURN_MS - turn_cnt) >= TURN_MIN_MS)) begin
                            // 【闭环提前收工】菱形锐角的转角比直角大，定长 TURN_MS
                            // 一到就交回 PID，车头还差一截 → 直接丢线滑走。
                            // 这里只要真的把线转回来了就停，时长只作上限。
                            turning <= 1'b0;
                            ms_cnt  <= 16'd0;
                            corner_cnt <= 16'd0;
                        end
                        if (obstacle) begin
                            turning <= 1'b0;        // 撞上障碍就放弃这次转向
                            ms_cnt  <= 16'd0;
                            avoid_tries <= 4'd0;
                            avoid_left  <= avoid_start_left;
                            state   <= avoid_entry_state;
                        end
                    end else begin
                        dir_l_des <= 1'b1;
                        dir_r_des <= 1'b1;
                        if (!dead) begin
                            duty_l <= pid_l;
                            duty_r <= pid_r;
                        end
                        // 收到转向请求：转入强制转向
                        if (turn_req && turn_allowed &&
                            ((TURN_WAIT_FOR_CORNER == 0) || (!obstacle && dir_evt == 3'd0))) begin
                            turn_req <= 1'b0;
                            turn_request_left <= 16'd0;
                            turning  <= 1'b1;
                            turn_cnt <= TURN_MS[15:0];
                            turn_line_cnt <= 16'd0;
                            turn_dir <= turn_left ? 2'd1 : 2'd2;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                            corner_cnt <= 16'd0;
                        end else if (obstacle) begin
                            ms_cnt <= 16'd0;
                            avoid_tries <= 4'd0;
                            avoid_left  <= avoid_start_left;
                            state  <= avoid_entry_state;
                        end else if (lost) begin
                            ms_cnt <= 16'd0;
                            state  <= S_LOST;
                        end
                    end
                end

                S_LOST: begin
                    // 保持最后一刻的占空比与方向
                    duty_l <= pid_l;
                    duty_r <= pid_r;
                    if (!lost && on_line) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else if (obstacle) begin
                        // 【盲区补漏】obstacle 原来只在 S_RUN 与 S_AVOID_PROBE 里检查。
                        // S_LOST 会按上一刻占空比继续前进 LOST_HOLD_MS(300 ms)，
                        // 按 0.4 m/s 约 10 cm —— 在 25 cm 阈值下完全来得及撞上去。
                        // 这里补上，与 S_RUN 走同一套避障入口。
                        ms_cnt <= 16'd0;
                        avoid_tries <= 4'd0;
                        avoid_left  <= avoid_start_left;
                        state  <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;
                    end else if (ms_cnt >= LOST_HOLD_MS - 1 &&
                                 ((TURN_WAIT_FOR_CORNER == 0) || dir_evt == 3'd0)) begin
                        ms_cnt <= 16'd0;
                        // ---- 找线方向决策（三级优先级）----
                        // ① 有转向牌事件（K230 识别到左/右转）：完全按牌走。
                        // ② 刚过拐角（宽黑后 CORNER_WIDE_MS 内）且没有牌：
                        //    按入弯前最后明确看到的线方位转（corner_side）；
                        //    从未看到过明确方位才用 DEFAULT_TURN_LEFT 兜底。
                        //    这是"没装 K230 / 没识别到牌"时的主要路径。
                        // ③ 其余情况（普通跑偏丢线）：线在哪边就往哪边转，
                        //    否则正常赛道上一旦偏出去就会朝反方向找，越找越远。
                        if (turn_req && turn_allowed &&
                            ((TURN_WAIT_FOR_CORNER == 0) || dir_evt == 3'd0)) begin
                            turn_req  <= 1'b0;
                            turn_request_left <= 16'd0;
                            dir_l_des <= turn_left ? 1'b0 : 1'b1;
                            dir_r_des <= turn_left ? 1'b1 : 1'b0;
                            turn_dir  <= turn_left ? 2'd1 : 2'd2;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                            corner_cnt <= 16'd0;
                        end else if (((DEFAULT_TURN_LEFT != 0) || corner_side_valid) &&
                                     (corner_cnt != 16'd0) &&
                                     ((TURN_WAIT_FOR_CORNER == 0) || !wide)) begin
                            // 拐角兜底：方向按"入弯前最后明确看到的线方位"决定。
                            // 线在左 → 左转（左轮后退、右轮前进）；
                            // 线在右 → 右转（左轮前进、右轮后退）。
                            // 只有从未看到过明确方位时才回落到 DEFAULT_TURN_LEFT（左转）。
                            if (corner_side_valid && !corner_side) begin
                                dir_l_des <= 1'b1;
                                dir_r_des <= 1'b0;
                                turn_dir  <= 2'd2;
                            end else begin
                                dir_l_des <= 1'b0;
                                dir_r_des <= 1'b1;
                                turn_dir  <= 2'd1;
                            end
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                            corner_cnt <= 16'd0;
                        end else begin
                            // 线在右边 → 向右转：左轮前进、右轮后退
                            dir_l_des <= ~last_pos_neg;
                            dir_r_des <=  last_pos_neg;
                            turn_dir  <= last_pos_neg ? 2'd1 : 2'd2;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                        end
                        duty_l    <= SEARCH_DUTY[10:0];
                        duty_r    <= SEARCH_DUTY[10:0];
                        state     <= S_SEARCH;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_SEARCH: begin
                    if (!dead) begin
                        duty_l <= SEARCH_DUTY[10:0];
                        duty_r <= SEARCH_DUTY[10:0];
                    end
                    if (!lost && on_line) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else if (obstacle) begin
                        // 【盲区补漏】原地图旋转找线期间完全不看障碍，而这段时间
                        // 车身一侧在反转、最长持续 SEARCH_MS(1.5 s)，贴着障碍转
                        // 很容易蹭上（细则 4.3.2 明确不得触碰）。同样转避障。
                        ms_cnt <= 16'd0;
                        avoid_tries <= 4'd0;
                        avoid_left  <= avoid_start_left;
                        state  <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;
                    end else if (ms_cnt >= SEARCH_MS - 1) begin
                        ms_cnt <= 16'd0;
                        // 桌面/小场地反复测试时，永久停车只能断电才能解除，非常难用。
                        // SEARCH_FAIL_TO_IDLE=1 改成回 IDLE：把车放回线上等 2 s 就重新起跑。
                        // 正式比赛改回 0（找线失败即判负，不能无限重试）。
                        if (SEARCH_FAIL_TO_IDLE != 0) begin
                            state <= S_IDLE;
                        end else begin
                            final_stop <= 1'b1;
                            state      <= S_STOP;
                        end
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_STOP: begin
                    duty_l <= 11'd0;
                    duty_r <= 11'd0;
                    // 只有"障碍导致的停车"且障碍消失才恢复；找线超时的停车保持
                    // AVOID_EN=1 时障碍不再进这里（走 BACK/TURN/PROBE），
                    // 所以这条恢复路径只对 AVOID_EN=0 的老行为有效。
                    if (!final_stop && !obstacle) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end
                end

                // ----------------------------------------------------------
                // 避障：后退 → 原地转（绕开障碍）→ 试探前进
                //   三段都是定长动作，不看线（这时候线通常已经被让开或压不到）；
                //   试探完还有障碍就再来一轮，最多 AVOID_TRIES 轮；
                //   用尽后进 S_STOP 等障碍消失，避免顶死在墙角反复撞。
                // ----------------------------------------------------------
                S_AVOID_BACK: begin
                    if (avoid_drive) begin
                        if (ms_cnt >= AVOID_BACK_MS - 1) begin
                            ms_cnt <= 16'd0;
                            state  <= S_AVOID_TURN;
                        end else begin
                            ms_cnt <= ms_cnt + 16'd1;
                        end
                    end
                end

                S_AVOID_TURN: begin
                    if (avoid_drive) begin
                        if (ms_cnt >= AVOID_TURN_MS - 1) begin
                            ms_cnt <= 16'd0;
                            state  <= S_AVOID_PROBE;
                        end else begin
                            ms_cnt <= ms_cnt + 16'd1;
                        end
                    end
                end

                S_AVOID_PROBE: begin
                    if (AVOID_ROUTE_EN != 0) begin
                        // 向外驶离 → 摆正 → 侧边超越 → 转向线内 → 低速回线。
                        // 这几段由避障控制，途中看到黑线也不能提前交回普通找线。
                        if (lost) bypass_left_line <= 1'b1;

                        if (bypass_blocked) begin
                            bypass_line_cnt <= 16'd0;
                            if (bypass_block_cnt >= AVOID_BLOCK_MS - 1) begin
                                final_stop <= 1'b1;
                                state <= S_STOP;
                            end else begin
                                bypass_block_cnt <= bypass_block_cnt + 16'd1;
                            end
                        end else if (avoid_drive) begin
                            bypass_block_cnt <= 16'd0;
                            ms_cnt <= ms_cnt + 16'd1;
                            case (bypass_step)
                                BY_OUT: if (arc_diff_done || (ms_cnt >= AVOID_OUT_MS - 1)) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_ALIGN;
                                end
                                BY_ALIGN: if (arc_diff_done || (ms_cnt >= AVOID_ALIGN_MS - 1)) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_PASS;
                                end
                                BY_PASS: if (arc_sum_done || (ms_cnt >= AVOID_PASS_MS - 1)) begin
                                    ms_cnt <= 16'd0;
                                    // 侧边超越结束后要判断"还能不能自己回线"：
                                    //   · 绕行途中离过线（bypass_left_line=1）且此刻仍
                                    //     丢线 → 正常回到 BY_TURN_IN 反向切回去；
                                    //   · 全程都骑在线上（bypass_left_line=0）→ 根本
                                    //     不需要回线动作，直接交回普通循迹。旧逻辑把
                                    //     这种情况也判成"找不回线"直接 final_stop，
                                    //     等于绕障绕到一半自己退赛。
                                    //   · 离过线但此刻已重新压线 → 同样交回循迹。
                                    if (bypass_left_line && lost) begin
                                        bypass_turn_in_cnt <= 16'd0;
                                        bypass_step <= BY_TURN_IN;
                                    end else if ((bypass_has_line) || !bypass_left_line) begin
                                        ms_cnt <= 16'd0;
                                        state  <= S_RUN;
                                    end else begin
                                        final_stop <= 1'b1;
                                        state <= S_STOP;
                                    end
                                end
                                BY_TURN_IN: begin
                                    // 原地转的同时找线：扫到线就提前收，AVOID_TURN_IN_MS 只是上限。
                                    // 原来纯定长 —— 电池电压、地面摩擦、起点角度一变，
                                    // 同一个 650 ms 转过的角度就差很多，现场表现就是
                                    // 「转得不够，之后一路找不到线」。改成闭环扫线后，
                                    // 转多少由"看到线"决定，不由时间决定。
                                    bypass_turn_in_cnt <= bypass_has_line
                                                        ? (bypass_turn_in_cnt + 16'd1) : 16'd0;
                                    if (bypass_turn_in_cnt >= AVOID_LINE_MS - 1) begin
                                        ms_cnt <= 16'd0;
                                        bypass_step <= BY_REJOIN;
                                    end else if (ms_cnt >= AVOID_TURN_IN_MS - 1) begin
                                        ms_cnt <= 16'd0;
                                        bypass_step <= BY_REJOIN;
                                    end
                                end
                                BY_REJOIN: begin
                                    if (bypass_has_line && bypass_line_cnt >= AVOID_LINE_MS - 1) begin
                                        ms_cnt <= 16'd0;
                                        state <= S_RUN;
                                    end else if (ms_cnt >= AVOID_REJOIN_MS - 1) begin
                                        final_stop <= 1'b1;
                                        state <= S_STOP;
                                    end else begin
                                        bypass_line_cnt <= bypass_has_line ? (bypass_line_cnt + 16'd1) : 16'd0;
                                    end
                                end
                                default: begin
                                    final_stop <= 1'b1;
                                    state <= S_STOP;
                                end
                            endcase
                        end
                    end else if (avoid_drive) begin
                        // 传统试探段供原有调用方式使用。
                        // 前 AVOID_PROBE_SETTLE_MS 不判障碍：刚转完身障碍还在正前方是
                        // 正常的，要等车真的往前探一段再判断"还堵着没"。
                        if (obstacle && (ms_cnt >= AVOID_PROBE_SETTLE_MS[15:0])) begin
                            // 还堵着：动作已经做完，再来一轮（或放弃）
                            ms_cnt <= 16'd0;
                            if (avoid_tries >= AVOID_TRIES - 1) begin
                                avoid_tries <= 4'd0;
                                state <= S_STOP;
                            end else begin
                                avoid_tries <= avoid_tries + 4'd1;
                                avoid_left  <= ~avoid_left;   // 换个方向再试
                                state <= S_AVOID_BACK;
                            end
                        end else if (ms_cnt >= AVOID_PROBE_MS - 1) begin
                            // 试探时间到。**不能无条件回 RUN**：绕行结束时车体朝向与线的
                            // 相对关系已经完全变了，按"线就在脚下"进 RUN 会用一份过期
                            // 的 pid 值瞎跑。压在线上才回 RUN，否则交给 S_LOST 找线。
                            ms_cnt      <= 16'd0;
                            avoid_tries <= 4'd0;
                            state       <= (!lost && on_line) ? S_RUN : S_LOST;
                        end else begin
                            ms_cnt <= ms_cnt + 16'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
