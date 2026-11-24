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
    parameter integer AVOID_PASS_DUTY    = 620,  // BY_PASS 直线超越，两轮同速（两轮平均）
    // 【v1.24 删除 AVOID_PASS_TRIM】v1.20 用 TRIM 把 PASS 段两轮差开成 480/760
    //   来抵消左右轮效率差。v1.21 接上航向闭环后，PASS 段两轮都取
    //   AVOID_PASS_DUTY，偏置改由 hdg_steer 实时给，这两个 localparam
    //   (AVOID_PASS_L_DUTY/AVOID_PASS_R_DUTY) 再无人引用 → 连同参数一起删除，
    //   否则调 AVOID_PASS_TRIM 是个"改了没反应"的死开关。
    parameter integer AVOID_TURN_IN_DUTY = 860,  // BY_TURN_IN 外侧快轮（反向弧切回线）
    parameter integer AVOID_TURN_IN_IN_DUTY = 420, // BY_TURN_IN 内侧慢轮
    parameter integer AVOID_REJOIN_IN_DUTY  = 430, // BY_REJOIN 内侧慢轮
    // 【v1.21 航向闭环参数】只数里程差只能保证「转够了停」，画出来的弧半径仍由
    //   两轮实际速度比决定；实车 duty→轮速 强非线性（同一 400/840 连发 12 帧，
    //   实测轮速比 0.66~1.85 乱跳），所以必须把「转角」当被控量实时修正。
    //   HDG_GAIN：每个计数误差（1 计数 ≈ 0.03°）折算多少占空比修正；
    //   HDG_DEAD：死区，吃掉量化抖动；HDG_STEER_*：修正量上下限。
    //   这些值只是让环「转得动、不抖」，最终精度由编码器差决定，不必精细标定。
    parameter integer HDG_SHIFT      = 3,    // 误差右移位数：steer = err >>> SHIFT
    // 【为什么是移位而不是乘法增益】每段起点的角度误差就是满量程（OUT/ALIGN 1999
    //   计数、TURN_IN 3000 计数），乘法增益 2 会立刻顶到 ±600，把慢轮压到占空比 0，
    //   等于原地打转 —— 那正是细则 4.3.2 禁止的动作。右移 3 位后起点修正量约
    //   250（OUT）/ 375（TURN_IN），落在「明显加大差速但不压停」的区间。
    parameter integer HDG_DEAD       = 10,   // 角度误差死区, 计数（≈0.30°）
    parameter integer HDG_STEER_MAX  = 600,  // 差速修正上限
    parameter integer HDG_STEER_MIN  = 60,   // 误差非零时的最小修正量
    // 【v1.23 参考角必须爬坡，不能阶跃】hdg_target 是**段终点的绝对目标角**，
    //   直接拿它算误差会出事：段起点的误差就是满量程（OUT/ALIGN 2334 计数、
    //   TURN_IN 2334 计数），>>>3 后立刻给出 ±290 的修正，把差速推到钳位，
    //   OUT 段的下发变成 1109/131 —— 等效弧半径从设计的 207mm 被压到 141mm，
    //   横向只挪开 141mm，而让开车体需要 NEED_LAT = 半宽 92.5 + 方块半宽 50
    //   = 142.5mm，于是「刚好擦着方块过去」（几何仿真最小间隙 0.0mm）。
    //   改成让参考角以 HDG_RAMP 计数/毫秒匀速爬向目标：段起点误差≈0，差速等于
    //   标称值，弧线回到设计半径；爬坡到位后再由闭环收残余误差。
    parameter integer HDG_RAMP       = 2,    // 参考角爬坡速率, 计数/毫秒（70° 约 1170ms）
    // 【v1.24 直行段加积分】纯 P 环在「两轮效率不等」时必然留一个稳态角度偏差：
    //   要抵消右轮只有左轮 0.55 的效率，620/620 下得持续给出约 ±207 的差速，
    //   而 hdg_p = err>>>3 要 err 爬到约 1656 计数（≈50°）才给得出 —— 实测 PASS
    //   段航向就稳在 +50° 偏差上不再回调，随后 TURN_IN 在这 +50° 基准上再加 70°，
    //   净转 +116°（设计 +70°）（run_avoid4，用户 m09199）。加积分把这个稳态偏差
    //   吃掉：误差再小，只要持续存在，积分就会慢慢推到刚好抵消效率差为止。
    // 【为什么只加在直行段】弧线段（OUT/ALIGN/TURN_IN）加积分反而更差：几何仿真
    //   里 KR/KL=0.55 的最小间隙从 100mm 掉到 17mm —— 积分让车严格按标称几何走，
    //   而标称几何横移只有 140.9mm < 需要的 142.5mm。弧线段靠纯 P 留一点偏差、
    //   把弧拉长一点，反而是它现在能躲开方块的原因。
    parameter integer HDG_I_SHIFT    = 5,    // 积分右移（Ki ≈ 1/32）
    parameter integer HDG_I_LIMIT    = 400,  // 积分累加上限（抗饱和）
    // 修正后单轮占空比的下限：低到 0 就成了枢轴原地转，必须留一点让它继续走。
    parameter integer AVOID_MIN_DUTY = 120,  // 航向修正后单轮占空比下限
    // 【弧线段改为里程闭环】原来 OUT/ALIGN/PASS 都是按毫秒截断的，而同样的
    // 毫秒数在不同车速下转过的角度完全不同 —— 电池电压、地面摩擦、载重一变，
    // 弧就画歪，轻则回不了线，重则直接蹭上方块。改成数编码器后，两轮计数
    // **差**只由航向变化决定，与车速无关，转角就稳定了。
    //   转角(度) = diff_cnt * 轮周长 / (每轮圈计数 * 轮距) * 180/pi
    //   转角(度) = 计数差 × 轮周长 / (每圈计数 × 轮距) × 180/pi
    // 【v1.18 实测重标定】下面两个数原来是从铭牌推算的（80×48=3840、周长232），
    //   实测不符：手转左轮 5 圈得 12662 计数 → 2532 计数/圈（三段 2522/7506/
    //   2634 独立吻合 ±2.7%，减速比其实是 31.7:1 而不是 48:1）；轮径用卡尺量
    //   67~68 mm → 周长 212 mm。于是每毫米计数 实测 11.94 / 原假设 16.55，
    //   原标定高 39%，60° 弧会转成 83°、BY_PASS 200mm 会走 277mm。
    // 真要改标定，只改 ENC_CNT_PER_REV / WHEEL_CIRC_MM / WHEEL_BASE_MM 三个数。
    //   当前：60 度 = 2000 个计数差；200 mm = 2388 计数/轮。
    parameter integer ENC_CNT_PER_REV  = 2532, // 每轮圈计数（实测，四倍频 × 减速比）
    parameter integer WHEEL_CIRC_MM    = 212,  // 轮周长, mm（实测轮径 67.5）
    parameter integer WHEEL_BASE_MM    = 160,  // 轮距, mm
    parameter integer AVOID_ARC_DEG    = 70,   // 单弧目标转角（度）
    // 【v1.20 TURN_IN 也需要角度闭环】OUT/ALIGN 一直有 arc_diff 闭环（实测
    //   确实在 2000 计数差附近切换，转角 −60°/+60° 达标），但 TURN_IN 只有
    //   "纯时间 + 扫线"两个出口：扫线要连续 AVOID_LINE_MS 拍压到线，而车
    //   正在大幅转向途中几乎压不到，于是每次都跑满 AVOID_TURN_IN_MS=1600ms。
    //   run_avoid1 实测这 1600 ms 转了 141°，目标是 60° —— 车头直接甩过去，
    //   REJOIN 再也找不回线。这里给 TURN_IN 自己一条角度判据：
    //     OUT 把车推到障碍侧边（−60°），ALIGN 反打摆正（+60°），
    //     PASS 直行超越，TURN_IN 再把车头反拧回朝线的方向。
    //   【v1.22 90°→60°，v1.23 60°→70°，v1.24 70°→40°】
    //   几何上 TURN_IN 的目标角**就是车最终切回原线时的航向角**（REJOIN 沿用同一个
    //   目标角继续斜切）。所以 70° 意味着车以 70°~90° 的姿态撞上原线 —— 那几乎是
    //   垂直穿越，而 track_pid 只有位置误差、没有航向状态，看到线也只能一路歪着
    //   修正，压一下就滑出去，这就是用户反复反馈的「垂直赛道走过去」。
    //   几何仿真（bench/hdg_profile_sim.py）扫角结果：
    //     过线航向 ≈ TURN_IN 设定角 + 0~20°（模型误差）
    //     TURN_IN=70 → 过线 72~93°；TURN_IN=40 → 过线 40°（六档效率全部 39.9±0.4°）
    //   而最小间隙**与 TURN_IN 无关**（只由 OUT 弧角决定，全程 72.1~105.2mm），
    //   所以收小 TURN_IN 不会让车更容易蹭到方块，纯粹改善回线姿态。
    //   OUT 仍保持 70°：出线弧的横移量（172mm > NEED_LAT 142.5mm）全靠它。
    parameter integer AVOID_TURN_IN_ARC_DEG = 40, // TURN_IN 目标转角（度）
    // 【v1.23 PASS 由 200mm 加长到 300mm】判据是 arc_sum >= 2×PASS_SUM_TARGET，
    //   即**两轮各自**都走满 AVOID_PASS_MM（不是两轮加起来）。200mm 时车身还没
    //   完全超越方块就开始回切，车尾扫到方块（几何仿真最小间隙 65.8mm，
    //   KR/KL=1.0 时只剩 65.8mm 且更小）；300mm 时升到 72.1mm，再往上收益饱和。
    parameter integer AVOID_PASS_MM    = 300,  // BY_PASS 直线超越距离, mm（每轮）
    // 下面两条 *_MS 已降级为**超时上限**：编码器不出脉冲时（没装/线松）仍能
    // 走完动作，不会卡死在半路。正常有编码器时提前里程到了就切换。
    parameter integer AVOID_OUT_MS      = 2500, // 外摆弧超时上限
    parameter integer AVOID_ALIGN_MS    = 2500, // 摆正弧超时上限
    // 【v1.17：编码器在线后，超时值必须放大】
    //   没装编码器时 arc_diff 恒 0，上面两个 *_MS 就是**真实弧长**（v1.16 按
    //   27~46 cm/s 标成 780/850/720）。一旦编码器真的出脉冲，弧线改由里程
    //   闭环提前结束，这组数退回纯兜底；若还按 780 卡，车速一慢（60° 弧要
    //   1160 ms）就会被提前截断，绕障又变成转不够。
    //   所以这里按「本段是否真的收到过编码器脉冲」二选一：
    //     enc_alive=1 → 用 AVOID_*_MS × AVOID_ENC_MULT 当宽松上限；
    //     enc_alive=0 → 原值（等于真实时长），与 v1.16 完全一致。
    parameter integer AVOID_ENC_MULT    = 4,
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
    // TURN_IN 的角度判据独立于 ARC_DIFF_TARGET（那条固定 60°，给 OUT/ALIGN 用）。
    // 60° = 1999 计数差 → 90° = 3000 计数差（1° ≈ 33.3 计数差）。
    localparam integer TURN_IN_MRAD       = (AVOID_TURN_IN_ARC_DEG * 31416 + 900) / 1800;
    localparam integer TURN_IN_ARC_TARGET = (TURN_IN_MRAD * ARC_CNT_PER_RAD) / 1000;
    // (v1.24 删除了无人引用的 AVOID_PASS_L_DUTY / AVOID_PASS_R_DUTY)
    reg [31:0] arc_cnt_l, arc_cnt_r;   // 本段内两轮各自累计脉冲
    reg [2:0]  arc_step_d, arc_state_d;// 上一拍的段号/状态，用来切段清零
    wire       arc_seg_new  = (state != arc_state_d) || (bypass_step != arc_step_d);
    wire [31:0] arc_diff    = (arc_cnt_l > arc_cnt_r) ? (arc_cnt_l - arc_cnt_r)
                                                      : (arc_cnt_r - arc_cnt_l);
    wire [31:0] arc_sum     = arc_cnt_l + arc_cnt_r;
    wire        arc_sum_done  = (arc_sum  >= (PASS_SUM_TARGET * 2));

    // ---------------- 航向闭环（v1.21）----------------
    // 【为什么光有里程还不够】里程差只能保证「转够了就停」，但弧的半径完全由
    //   两轮实际速度比决定，而实车 duty→轮速 强烈非线性（同一对 400/840 连发
    //   12 帧，实测轮速比在 0.66~1.85 之间乱跳；duty=760 甚至比 840 更快）。
    //   于是固定占空比画不出固定半径：run_avoid2 四次绕障净转角
    //   +38°/+103°/−37°，终点跑到黑线半米外。
    //   这里把「转角」当被控量：每毫秒用编码器差算出真实转角，与目标角比较，
    //   误差实时换成两轮差速修正量叠在标称占空比上。转够即切段，转不动就自动
    //   加大差速 —— 半径仍不确定，但每个拐点的绝对航向被钉住，误差不再跨段累积。
    // 符号约定：右轮走得多 = 左转 = 累积航向为正。两轮都正转时左轮慢就是左转。
    // 【v1.22 累积航向 + 绝对剖面】原来 arc_cnt_l/r 每换一段就被 arc_seg_new 清零，
    //   于是每段的目标角都是「相对本段起点」，误差不跨段继承：
    //     ALIGN 走超时出口只转回 36°（目标 60°），欠下的 24° 被彻底丢掉；
    //     PASS 把「保持本段航向」当目标，于是带着 ALIGN 剩下的偏差一路走 ——
    //     现场就是「第三段继续往右偏」；
    //     TURN_IN 又在已经偏了的基准上再叠加 90°，绝对航向严重超标，
    //     现场就是「转得过多、车头垂直赛道」。
    //   改成整次绕障只清一次零，各段给出**相对绕障起点的绝对剖面**：
    //     OUT     →  A·ARC_TARGET         朝绕行侧摆出去（A 由 avoid_left 定）
    //     ALIGN   →  0                    反打摆正，与出线前平行
    //     PASS    →  0                    保持平行，直行超越障碍
    //     TURN_IN → −A·TURN_IN_TARGET     反向切回原线（默认 60°，与 OUT 对称）
    //     REJOIN  → −A·TURN_IN_TARGET     保持 TURN_IN 的斜切姿态，靠斜穿压线
    //   欠转的角度自然变成下一段要多转的量，最终绝对航向始终有人负责。
    reg [31:0] hdg_cnt_l, hdg_cnt_r;   // 本次绕障累计脉冲（段间绝不清零）
    wire signed [23:0] arc_turn = $signed({1'b0, hdg_cnt_r[22:0]})
                                - $signed({1'b0, hdg_cnt_l[22:0]});
    // 编码器一个脉冲都没有时，所有「到位」出口都必须禁用，退回毫秒超时。
    wire        hdg_alive = (hdg_cnt_l != 32'd0) || (hdg_cnt_r != 32'd0);
    wire        hdg_out_left = avoid_left;   // 出线弧朝哪边：左绕=左转=arc_turn 变大
    // 本段该沿哪个方向逼近目标（+1 = 让 arc_turn 变大 = 左转）。
    //   PASS 取 0：不判到位，只做航向保持。
    wire signed [1:0] hdg_dir = (bypass_step == BY_OUT)    ? (hdg_out_left ?  2'sd1 : -2'sd1) :
                                (bypass_step == BY_PASS)   ?  2'sd0 :
                                (bypass_step == BY_REJOIN) ? (hdg_out_left ?  2'sd1 : -2'sd1) :
                                                             (hdg_out_left ? -2'sd1 :  2'sd1);
    // 本段绝对目标角（相对本次绕障起点）。用显式 24 位 signed 常量，
    //   避免对 integer 型 localparam 做拼接（部分工具会按 32 位无符号解释）。
    wire signed [23:0] arc_tgt_s  = ARC_DIFF_TARGET;
    wire signed [23:0] turn_tgt_s = TURN_IN_ARC_TARGET;
    wire signed [23:0] hdg_target =
        (bypass_step == BY_OUT)     ? (hdg_out_left ?  arc_tgt_s  : -arc_tgt_s)  :
        (bypass_step == BY_ALIGN)   ?  24'sd0 :   // 反打摆正，回到平行
        (bypass_step == BY_PASS)    ?  24'sd0 :   // 保持平行，直行超越障碍
        /* TURN_IN / REJOIN */        (hdg_out_left ? -turn_tgt_s :  turn_tgt_s);
    // 【v1.23 REJOIN 不能再摆平】v1.22 把 REJOIN 的目标设成 0，等于 TURN_IN 刚把车头
    //   从 −70° 斜切到 +70°（朝原线），一进 REJOIN 又被拧回平行 → 车平行前进、永远
    //   压不到原线，AVOID_REJOIN_MS 用尽后去 S_SEARCH 漫天找线（用户 m08026「直接飞
    //   到平行赛道去了」）。正解是保持斜切姿态继续走，靠斜穿压线；压到线后由
    //   bypass_has_line && bypass_line_cnt ≥ AVOID_LINE_MS-1 切回 S_RUN。
    // 【v1.23 参考角爬坡寄存器】段起点把 hdg_ref 对齐到当时的实测转角（误差归零，
    //   差速回到标称值、弧线回到设计半径），之后每个毫秒朝 hdg_target 挪 HDG_RAMP
    //   个计数，爬到目标就停住。不用阶跃值直接算误差是 v1.22 擦方块的原因。
    reg signed [23:0] hdg_ref;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            hdg_ref <= 24'sd0;
        end else if (arc_seg_new) begin
            // 换段瞬间把参考角钉在实测角上：本段误差 = 0，不会一进段就满量程修正。
            hdg_ref <= arc_turn;
        end else if (ms_tick) begin
            if (hdg_ref < hdg_target) begin
                hdg_ref <= (hdg_ref + HDG_RAMP >= hdg_target) ? hdg_target
                                                              : (hdg_ref + HDG_RAMP);
            end else if (hdg_ref > hdg_target) begin
                hdg_ref <= (hdg_ref - HDG_RAMP <= hdg_target) ? hdg_target
                                                              : (hdg_ref - HDG_RAMP);
            end
        end
    // 还差多少角度：>0 表示还得继续左转（修正量符号与占空比叠加同源）。
    wire signed [23:0] hdg_err = hdg_ref - arc_turn;   // 用爬坡参考，不用段终点目标
    // 【到位判据必须带符号】原来 arc_diff 取了绝对值，往反方向转同样多计数也会
    //   被判成「到位」——run_avoid2 的 ALIGN 反打 36° 就是这样被接受的。
    //   现在按本段该走的方向越过绝对目标才算到位，反方向永远越不过去。
    wire hdg_at_target = (hdg_dir > 2'sd0) ? (arc_turn >= hdg_target) :
                         (hdg_dir < 2'sd0) ? (arc_turn <= hdg_target) : 1'b0;
    wire hdg_seg_done  = hdg_alive && hdg_at_target && (hdg_dir != 2'sd0);
    wire arc_diff_done    = hdg_seg_done && ((bypass_step == BY_OUT) || (bypass_step == BY_ALIGN));
    wire turn_in_arc_done = hdg_seg_done && (bypass_step == BY_TURN_IN);
    // 角度误差 → 差速修正量。死区吃掉量化抖动；饱和与最小修正量保证末段不掉速。
    wire signed [23:0] hdg_err_dz = (hdg_err >  HDG_DEAD) ? (hdg_err - HDG_DEAD) :
                                    (hdg_err < -HDG_DEAD) ? (hdg_err + HDG_DEAD) : 24'sd0;
    // 算术右移：hdg_err_dz 是 signed，>>> 保留符号，等价于整除 2^HDG_SHIFT。
    wire signed [23:0] hdg_p      = hdg_err_dz >>> HDG_SHIFT;
    // 【v1.24 积分项】只在 PASS / REJOIN 两个直行段累积，换段清零（见参数区注释）。
    //   积分吃的是「死区后的残差」：死区宽度仍是硬指标，不会因积分把抖动累起来。
    //   累积量钳在 ±HDG_I_LIMIT，避免长时间偏差把积分养肥后过冲。
    wire        hdg_i_on = (bypass_step == BY_PASS) || (bypass_step == BY_REJOIN);
    wire signed [23:0] hdg_i_inc = hdg_err_dz >>> HDG_I_SHIFT;
    reg signed [23:0] hdg_i_acc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)            hdg_i_acc <= 24'sd0;
        else if (arc_seg_new)  hdg_i_acc <= 24'sd0;   // 换段清零，误差不跨段继承
        else if (!hdg_i_on)    hdg_i_acc <= 24'sd0;   // 弧线段不用积分
        else if (ms_tick) begin
            if (hdg_i_acc + hdg_i_inc >  HDG_I_LIMIT) hdg_i_acc <=  HDG_I_LIMIT;
            else if (hdg_i_acc + hdg_i_inc < -HDG_I_LIMIT) hdg_i_acc <= -HDG_I_LIMIT;
            else hdg_i_acc <= hdg_i_acc + hdg_i_inc;
        end
    wire signed [23:0] hdg_pi     = hdg_p + (hdg_i_on ? hdg_i_acc : 24'sd0);
    wire signed [23:0] hdg_steer  = (hdg_pi >  HDG_STEER_MAX) ?  HDG_STEER_MAX :
                                    (hdg_pi < -HDG_STEER_MAX) ? -HDG_STEER_MAX :
                                    (hdg_err_dz > 0 && hdg_pi <  HDG_STEER_MIN) ?  HDG_STEER_MIN :
                                    (hdg_err_dz < 0 && hdg_pi > -HDG_STEER_MIN) ? -HDG_STEER_MIN :
                                                                                  hdg_pi;
    // 本段内是否真的收到过脉冲：收到就说明编码器在线，超时值可以放宽成纯兜底；
    // 一个都没有就说明没装/线松，此时 *_MS 仍是真实弧长，不能放大。
    wire        arc_enc_alive = (arc_cnt_l != 32'd0) || (arc_cnt_r != 32'd0);
    wire [31:0] avoid_out_ceil   = arc_enc_alive ? (AVOID_OUT_MS   * AVOID_ENC_MULT) : AVOID_OUT_MS;
    wire [31:0] avoid_align_ceil = arc_enc_alive ? (AVOID_ALIGN_MS * AVOID_ENC_MULT) : AVOID_ALIGN_MS;
    wire [31:0] avoid_pass_ceil  = arc_enc_alive ? (AVOID_PASS_MS  * AVOID_ENC_MULT) : AVOID_PASS_MS;
    // TURN_IN 也一样：90° 在满电时约 1.0 s，电池掉压、地面变滑就可能超过
    // AVOID_TURN_IN_MS=1600，若还按 1600 卡，角度闭环根本没机会生效。
    wire [31:0] avoid_turn_in_ceil = arc_enc_alive ? (AVOID_TURN_IN_MS * AVOID_ENC_MULT) : AVOID_TURN_IN_MS;
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
    // (1) 标称占空比：只决定「大概多快、往哪边」，不再承担确定几何的责任。
    wire [10:0] avoid_duty_l_nom = avoid_backing ? AVOID_BACK_DUTY[10:0] :
                               avoid_pivot   ? AVOID_TURN_DUTY[10:0] :
                               !bypass_active ? AVOID_PROBE_DUTY[10:0] :
                               bypass_straight ? AVOID_PASS_DUTY[10:0] :
                               bypass_arc_left ? bypass_inner : bypass_outer;
    wire [10:0] avoid_duty_r_nom = avoid_backing ? AVOID_BACK_DUTY[10:0] :
                               avoid_pivot   ? AVOID_TURN_DUTY[10:0] :
                               !bypass_active ? AVOID_PROBE_DUTY[10:0] :
                               bypass_straight ? AVOID_PASS_DUTY[10:0] :
                               bypass_arc_left ? bypass_outer : bypass_inner;

    // (2) 航向修正量叠在标称值上：hdg_steer>0 = 还差左转 → 左轮减、右轮加。
    //   从此「画弧半径」由闭环自己收敛，不再依赖 duty→轮速 这个坏掉的静态映射。
    //   【v1.22 BY_REJOIN 也进闭环】原来 REJOIN 被排除，只有固定 430/640 + 扫线：
    //   车头已被 TURN_IN 摆到斜向，固定差速既摆不正也不受控，20 ms 连续压线判据
    //   又几乎不可能满足 → 一路冲到平行赛道。现在 REJOIN 的目标角是 0（摆平），
    //   由同一个环负责把残余航向收干净，扫线只负责最后那一下认线。
    wire        hdg_apply = bypass_active && !avoid_pivot;
    wire signed [23:0] avoid_l_s = $signed({13'd0, avoid_duty_l_nom})
                                 - (hdg_apply ? hdg_steer : 24'sd0);
    wire signed [23:0] avoid_r_s = $signed({13'd0, avoid_duty_r_nom})
                                 + (hdg_apply ? hdg_steer : 24'sd0);
    // 钳到合法区间：上限 DUTY_MAX=1200；下限不是 0 而是 AVOID_MIN_DUTY=120。
    // 【下限为什么不能是 0】TURN_IN 起点误差就是满量程 3000 计数，右移 3 位 = 375，
    //   叠在标称内轮 420 上算出来只剩 45 —— 内侧轮几乎不动，等于原地打转，正是
    //   细则 4.3.2 禁止的动作。留 120 的下限保证该轮仍在转、车走的是弧而不是枢轴。
    //   代价是极限情况下修正量被截断，但它只在段首 1~2 ms 出现，编码器一累计就回落。
    wire [10:0] avoid_duty_l = (avoid_l_s <= AVOID_MIN_DUTY) ? AVOID_MIN_DUTY[10:0] :
                               (avoid_l_s >= 24'sd1200)      ? 11'd1200 : avoid_l_s[10:0];
    wire [10:0] avoid_duty_r = (avoid_r_s <= AVOID_MIN_DUTY) ? AVOID_MIN_DUTY[10:0] :
                               (avoid_r_s >= 24'sd1200)      ? 11'd1200 : avoid_r_s[10:0];

    // 弧线段两轮都正转；后退段两轮都反转；只有老的三段试探里的原地转才一正一反。
    wire avoid_dir_l = avoid_backing ? 1'b0 : avoid_pivot ? !avoid_turn_left : 1'b1;
    wire avoid_dir_r = avoid_backing ? 1'b0 : avoid_pivot ?  avoid_turn_left : 1'b1;

    // 每段只在死区结束、两轮方向就绪后计时。
    wire avoid_dirs_ready = !dead && !bypass_blocked &&
                            (dir_l == avoid_dir_l) && (dir_r == avoid_dir_r);
    // 【v1.21 改掉「占空比严格相等」这个就绪判据】
    //   原判据是 duty_l == avoid_duty_l && duty_r == avoid_duty_r，本意是「指令已真正
    //   下发到电机，再开始数编码器」。一旦占空比带航向修正，它每拍都在变，而
    //   duty_l/duty_r 只在 ms_tick 才更新 → 比较几乎每个周期都不成立 → avoid_drive
    //   抖成 0 → en 抖成 0 → 弧线计数与 ms_cnt 全部停走（状态机就此卡死）。
    //   现在「就绪」只表示方向对、不在换相死区。指令与应用的 1 拍滞后（约 42 ns）
    //   对编码器计数的影响远小于 1 个脉冲，可以忽略。
    wire avoid_drive = avoid_dirs_ready;

    wire en_run = (state == S_RUN)   || (state == S_LOST)     || (state == S_SEARCH)
               || avoid_active;
    assign en = en_run && !dead && (!avoid_active || avoid_drive);

    // 【v1.22 两套计数器，用途不同，别混】
    //   arc_cnt_l/r：**每段**清零，给 PASS 的里程判据（arc_sum ≥ 2×PASS_SUM_TARGET）
    //                和 sim/arc_mileage_tb 的 `dut.arc_diff` 用，语义是「本段走了多少」。
    //   hdg_cnt_l/r：**整次绕障**只清一次零，给绝对航向剖面用，语义是「这次绕障
    //                累计转了多少」。段间清零正是 v1.21 丢误差的根源，这里必须分开。
    // ---- 段内里程计数（每段清零）----
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

    // ---- 整次绕障累计航向计数（只在绕障结束后清零）----
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            hdg_cnt_l <= 32'd0;
            hdg_cnt_r <= 32'd0;
        end else if (!bypass_active) begin
            // 没在绕障（含刚退出）就清零，保证下一次绕障从绝对零点开始。
            hdg_cnt_l <= 32'd0;
            hdg_cnt_r <= 32'd0;
        end else if (avoid_drive) begin
            if (enc_l_step) hdg_cnt_l <= hdg_cnt_l + 32'd1;
            if (enc_r_step) hdg_cnt_r <= hdg_cnt_r + 32'd1;
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
                                BY_OUT: if (arc_diff_done || (ms_cnt >= avoid_out_ceil - 1)) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_ALIGN;
                                end
                                BY_ALIGN: if (arc_diff_done || (ms_cnt >= avoid_align_ceil - 1)) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_PASS;
                                end
                                BY_PASS: if (arc_sum_done || (ms_cnt >= avoid_pass_ceil - 1)) begin
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
                                    end else if (turn_in_arc_done) begin
                                        // 【v1.20 角度闭环】转过 TURN_IN_ARC_TARGET
                                        // （默认 90°）就收，不再等满 1600 ms。
                                        // 实测原来 1600 ms 转 141°，车头直接
                                        // 甩过头，REJOIN 再也看不到线。
                                        ms_cnt <= 16'd0;
                                        bypass_step <= BY_REJOIN;
                                    end else if (ms_cnt >= avoid_turn_in_ceil - 1) begin
                                        ms_cnt <= 16'd0;
                                        bypass_step <= BY_REJOIN;
                                    end
                                end
                                BY_REJOIN: begin
                                    if (bypass_has_line && bypass_line_cnt >= AVOID_LINE_MS - 1) begin
                                        ms_cnt <= 16'd0;
                                        state <= S_RUN;
                                    end else if (ms_cnt >= AVOID_REJOIN_MS - 1) begin
                                        // 【v1.20 超时改走找线】原来这里直接
                                        // final_stop + S_STOP：绕障绕到一半自己
                                        // 退赛，比绕不开还糟。REJOIN 超时说明
                                        // "斜切若干毫米还没压到线"，正确反应是
                                        // 原地转着扫线（和 S_LOST → S_SEARCH 同款），
                                        // 给 SEARCH_MS 一个机会，失败再按
                                        // SEARCH_FAIL_TO_IDLE 的规则停车。
                                        ms_cnt <= 16'd0;
                                        dir_l_des <= ~last_pos_neg;
                                        dir_r_des <=  last_pos_neg;
                                        turn_dir  <= last_pos_neg ? 2'd1 : 2'd2;
                                        turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                                        state <= S_SEARCH;
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
