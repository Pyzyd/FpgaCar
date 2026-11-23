// =============================================================================
// duty_shaper.v —— 差速幅度整形（过弯动作幅度/变化率限制）
// -----------------------------------------------------------------------------
// 【解决什么问题】
//   track_pid 的 corr 被限幅在 ±BASE_DUTY(480)，而 base 也是 480。于是只要位置误差
//   大到让 corr 顶到 480，两轮占空比就是 960 / 0 —— 内侧轮**精确等于 0**。
//   0 占空比不是"慢转"，是电机既不出力又被反电动势和减速箱拖着，接近刹车。
//   差速三轮的瞬时旋转中心落在两驱动轮连线上，内侧轮一旦从"驱动"变成"被拖"，
//   纵向约束少了一条，旋转中心开始沿线漂移 → 车尾横向甩出去。
//
//   从几何上看更直接：两轮占空比 960/0 对应 内/外 = 0，即 (R-W/2)/(R+W/2)=0
//   → R = W/2 = 80 mm（WHEEL_BASE_MM/2）。PID 饱和时的等效指令是"绕车体中心原地转"，
//   而赛道圆弧半径通常 200 mm 以上。指令本身远超实际需要，这是过弯动作过大的根。
//
// 【怎么整形】三步，互相独立，都可以单独关掉：
//   1) 差速缩放（DIFF_SHIFT）：把两轮差速按 1/2^DIFF_SHIFT 压缩，均值不变。
//      960/0 → 720/240（DIFF_SHIFT=1）。内侧轮保持在能出力的区间，
//      等效最小转弯半径从 80 mm 变成 240 mm，仍足够过赛道弯。
//      这一步减的是"动作幅度"。
//   2) 低占空比地板（MIN_DUTY）：占空比非零但低于地板时抬到地板。
//      0 保持 0（停车语义不变），只救"给了指令但转不动"的半死区。
//      注意：地板会把内侧轮抬高、从而减小差速，与第 1 步同向。
//   3) 斜率限制（SLEW_STEP）：每个 ms 的占空比变化不超过 SLEW_STEP 计数。
//      消掉单拍跳变（例如 480 → 960）。代价是相位滞后，故默认关闭，
//      需要实测确认不会引入摆振再打开。
//
// 【什么时候才整形】follow=1 才做第 1 步。follow 由顶层给出，含义是
//   "正在循迹且两轮同向"（S_RUN / S_LOST 且 dir_l==dir_r）。原因：
//   * 原地转（交通牌 TURN / 找线 SEARCH）两轮反向，差速不是"转向量"而是动作本身，
//     整形只会把它转不动。
//   * 避障侧绕（S_AVOID_*）是里程闭环的圆弧，改差速会改半径，虽然闭环仍会收敛
//     但会偏离标定过的路径，故不介入。
//   * 停车（duty=0）时地板不得把车顶起来，所以地板只作用于"非零且过小"的值。
//
// 【为什么不直接在 track_pid 里改】track_pid 的 ±BASE 限幅同时保证了两轮都落在
//   0..2*BASE，是有意义的内部不变式，且它的单测按这个行为写死。整形是输出层的
//   工程约束（电机死区、动作幅度），放在 PID 之后的独立一级，两边的语义都干净。
// =============================================================================
`timescale 1ns/1ns

module duty_shaper #(
    parameter integer CLK_FREQ   = 24_000_000,
    parameter integer DUTY_MAX   = 1200,   // = CLK_FREQ / PWM_FREQ
    parameter integer DIFF_SHIFT = 1,      // 差速 >> DIFF_SHIFT（1=减半，0=不缩放）
    parameter integer MIN_DUTY   = 0,      // 低占空比地板（0=关闭）
    parameter integer SLEW_STEP  = 0       // 每 ms 最大变化量（0=关闭）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,           // 0 = 直通（停机/换相死区/非 RUN）
    input  wire        follow,       // 1 = 循迹同向工况，允许差速缩放
    input  wire [10:0] duty_l_in,
    input  wire [10:0] duty_r_in,
    output reg  [10:0] duty_l_out,
    output reg  [10:0] duty_r_out
);

    localparam integer MS_DIV = CLK_FREQ / 1000;

    // ---------------- 1 ms 节拍 ----------------
    reg [31:0] ms_cnt;
    wire       tick = (ms_cnt >= MS_DIV - 1);

    // ---------------- 目标值（组合） ----------------
    // 13 位有符号足够：输入最大 1200，mid ± diff 不会超出 ±1200。
    wire signed [12:0] dl = $signed({2'b00, duty_l_in});
    wire signed [12:0] dr = $signed({2'b00, duty_r_in});

    // 均值/差速分解：mid 是"平均前进量"，diff 是"转向量"。
    // 只压 diff、不动 mid，所以压幅度不会改变车的整体速度。
    wire signed [12:0] mid  = (dl + dr) >>> 1;
    wire signed [12:0] diff = (dl - dr) >>> 1;

    // 算术右移：diff 为负时也正确（向 -inf 取整，误差 1 计数可忽略）
    wire signed [12:0] diff_s = follow ? (diff >>> DIFF_SHIFT) : diff;

    wire signed [12:0] tgt_l = mid + diff_s;
    wire signed [12:0] tgt_r = mid - diff_s;

    wire signed [12:0] maxv = DUTY_MAX;

    // ---------------- 钳位 + 地板 ----------------
    wire [10:0] cl_l = (tgt_l < 0) ? 11'd0 : (tgt_l > maxv) ? DUTY_MAX[10:0] : tgt_l[10:0];
    wire [10:0] cl_r = (tgt_r < 0) ? 11'd0 : (tgt_r > maxv) ? DUTY_MAX[10:0] : tgt_r[10:0];

    // 只抬"非零且过小"，0 保持 0 —— 否则停车状态会被地板顶起来。
    wire [10:0] fl_l = ((cl_l != 11'd0) && (cl_l < MIN_DUTY)) ? MIN_DUTY[10:0] : cl_l;
    wire [10:0] fl_r = ((cl_r != 11'd0) && (cl_r < MIN_DUTY)) ? MIN_DUTY[10:0] : cl_r;

    // ---------------- 斜率限制 ----------------
    reg [10:0] cur_l, cur_r;

    wire signed [12:0] step_l = $signed({2'b00, fl_l}) - $signed({2'b00, cur_l});
    wire signed [12:0] step_r = $signed({2'b00, fl_r}) - $signed({2'b00, cur_r});

    wire signed [12:0] slew = SLEW_STEP;
    wire signed [12:0] st_l = (step_l >  slew) ?  slew :
                              (step_l < -slew) ? -slew : step_l;
    wire signed [12:0] st_r = (step_r >  slew) ?  slew :
                              (step_r < -slew) ? -slew : step_r;

    // SLEW_STEP=0 时直接跟随目标（无滞后）；否则按每 ms 上限逼近。
    wire signed [12:0] nx_l_s = (SLEW_STEP == 0) ? $signed({2'b00, fl_l})
                                                 : ($signed({2'b00, cur_l}) + st_l);
    wire signed [12:0] nx_r_s = (SLEW_STEP == 0) ? $signed({2'b00, fl_r})
                                                 : ($signed({2'b00, cur_r}) + st_r);

    wire [10:0] nx_l = (nx_l_s < 0) ? 11'd0 : (nx_l_s > maxv) ? DUTY_MAX[10:0] : nx_l_s[10:0];
    wire [10:0] nx_r = (nx_r_s < 0) ? 11'd0 : (nx_r_s > maxv) ? DUTY_MAX[10:0] : nx_r_s[10:0];

    // ---------------- 输出 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_cnt     <= 32'd0;
            cur_l      <= 11'd0;
            cur_r      <= 11'd0;
            duty_l_out <= 11'd0;
            duty_r_out <= 11'd0;
        end else begin
            ms_cnt <= tick ? 32'd0 : ms_cnt + 32'd1;

            if (!en) begin
                // 直通：每拍跟住输入，不引入任何滞后。
                // 换相死区期间 car_fsm 已把 duty 清 0，这里跟着清，不破坏死区。
                cur_l      <= duty_l_in;
                cur_r      <= duty_r_in;
                duty_l_out <= duty_l_in;
                duty_r_out <= duty_r_in;
            end else if (tick) begin
                cur_l      <= nx_l;
                cur_r      <= nx_r;
                duty_l_out <= nx_l;
                duty_r_out <= nx_r;
            end
        end
    end

endmodule
