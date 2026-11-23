`timescale 1ns/1ns

module parking_motion #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer COUNTS_PER_REV = 2532,
    parameter integer WHEEL_CIRC_MM = 212,
    parameter integer WHEEL_BASE_MM = 164,
    parameter integer REVERSE_MM = 300,
    parameter integer EXIT_LIMIT_MM = 450,
    parameter [10:0] PIVOT_DUTY = 11'd300,
    parameter [10:0] STRAIGHT_DUTY = 11'd300,
    parameter [10:0] FOLLOW_MAX_DUTY = 11'd300
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               run_enable,
    input  wire signed [31:0] position_l,
    input  wire signed [31:0] position_r,
    input  wire               line_seen,
    input  wire               line_valid,
    input  wire               line_centered,
    input  wire [10:0]        follow_duty_l,
    input  wire [10:0]        follow_duty_r,
    output wire               active,
    output wire               following,
    output wire               stopped,
    output reg                fault,
    output reg  [1:0]         reverse_fault,
    output reg  [2:0]         status,
    output reg                forward_l,
    output reg                forward_r,
    output reg  [10:0]        duty_l,
    output reg  [10:0]        duty_r
);
    localparam [3:0] IDLE = 0, DELAY = 1, ENTRY_TURN = 2, ENTRY_BRAKE = 3,
                     REVERSE = 4, PARKED = 5, EXIT_STRAIGHT = 6, EXIT_BRAKE = 7,
                     EXIT_TURN = 8, FOLLOW = 9, FAULT = 10;

    localparam integer MS_CYCLES = CLK_FREQ / 1000;
    localparam integer TICK_W = (MS_CYCLES <= 1) ? 1 : $clog2(MS_CYCLES);
    localparam integer START_MS = 2000, BRAKE_MS = 150, PARK_MS = 5000;
    localparam integer PIVOT_LIMIT_MS = 5000, REVERSE_LIMIT_MS = 8000,
                       EXIT_LIMIT_MS = 10000, CHECK_ENCODER_MS = 900;
    localparam integer CLEAR_MS = 30, LINE_MS = 12, CENTER_MS = 25, LOST_MS = 180;

    // 单轮绕另一轮转 90° 的弧长为 π × 轮距 / 2。乘积用 64 位防止常量溢出。
    localparam integer TURN_COUNTS =
        (64'd314159 * WHEEL_BASE_MM * COUNTS_PER_REV + 100000 * WHEEL_CIRC_MM)
        / (200000 * WHEEL_CIRC_MM);
    localparam integer REVERSE_COUNTS =
        (REVERSE_MM * COUNTS_PER_REV + WHEEL_CIRC_MM / 2) / WHEEL_CIRC_MM;
    localparam integer EXIT_COUNTS = EXIT_LIMIT_MM * COUNTS_PER_REV / WHEEL_CIRC_MM;
    localparam integer RETURN_MIN = TURN_COUNTS * 5 / 6;
    localparam integer RETURN_MAX = TURN_COUNTS * 7 / 6;
    localparam integer WRONG_WAY_COUNTS = 36, START_COUNTS = 24;
    localparam integer PIVOT_DRIFT = 180, STRAIGHT_DRIFT = 300;
    localparam signed [31:0] TRIM_LIMIT = 36;
    localparam signed [31:0] REVERSE_TRIM_LIMIT = 60, CATCH_GAP = 144, RESUME_GAP = 72;
    localparam [10:0] CATCH_DUTY = STRAIGHT_DUTY + REVERSE_TRIM_LIMIT;
    localparam integer REVERSE_DRIFT_LIMIT = 600, REVERSE_STALL_MS = 800, PROGRESS_COUNTS = 8;
    localparam [1:0] REVERSE_OK = 0, REVERSE_WRONG_WAY = 1,
                     REVERSE_STALLED = 2, REVERSE_LIMIT = 3;

    reg [3:0] state, next_state;
    reg [TICK_W-1:0] tick_count;
    reg [15:0] elapsed_ms;
    reg [7:0] hold_ms;
    reg exit_armed;
    reg signed [31:0] start_l, start_r;
    reg pause_l, pause_r;
    reg [9:0] idle_l_ms, idle_r_ms;
    reg signed [31:0] last_progress_l, last_progress_r;

    wire ms_tick = (tick_count == MS_CYCLES - 1);
    wire signed [31:0] delta_l = position_l - start_l;
    wire signed [31:0] delta_r = position_r - start_r;

    // 左右按实际车轮位置命名，前进均为正，倒车阶段把累计值转成行进方向的量。
    wire signed [31:0] along_l = (state == REVERSE) ? -delta_l : delta_l;
    wire signed [31:0] along_r = (state == REVERSE) ? -delta_r : delta_r;
    wire signed [32:0] sum_along = $signed({along_l[31], along_l})
                                 + $signed({along_r[31], along_r});
    wire signed [31:0] straight_error = along_l - along_r;
    wire signed [31:0] trim_raw = straight_error / 4;
    wire signed [31:0] trim_limit = (state == REVERSE) ? REVERSE_TRIM_LIMIT : TRIM_LIMIT;
    wire signed [31:0] trim = (trim_raw > trim_limit) ? trim_limit :
                              (trim_raw < -trim_limit) ? -trim_limit : trim_raw;
    wire signed [11:0] straight_l = $signed({1'b0, STRAIGHT_DUTY}) - $signed(trim[11:0]);
    wire signed [11:0] straight_r = $signed({1'b0, STRAIGHT_DUTY}) + $signed(trim[11:0]);

    wire signed [31:0] pivot_left = (state == ENTRY_TURN) ? -delta_l : delta_l;
    wire signed [31:0] pivot_yaw = (state == ENTRY_TURN) ? delta_r - delta_l : delta_l - delta_r;
    wire pivot_failed = (elapsed_ms >= PIVOT_LIMIT_MS) ||
                        (pivot_left < -WRONG_WAY_COUNTS) ||
                        (delta_r > PIVOT_DRIFT) || (delta_r < -PIVOT_DRIFT) ||
                        (elapsed_ms >= CHECK_ENCODER_MS && pivot_left < START_COUNTS);
    wire straight_failed = (along_l < -WRONG_WAY_COUNTS) || (along_r < -WRONG_WAY_COUNTS) ||
                           (straight_error > STRAIGHT_DRIFT) ||
                           (straight_error < -STRAIGHT_DRIFT) ||
                           (elapsed_ms >= CHECK_ENCODER_MS &&
                            (along_l < START_COUNTS || along_r < START_COUNTS));
    wire reverse_done_l = (along_l >= REVERSE_COUNTS);
    wire reverse_done_r = (along_r >= REVERSE_COUNTS);
    wire brake_l = reverse_done_l || pause_l;
    wire brake_r = reverse_done_r || pause_r;
    wire reverse_wrong_way = (along_l < -WRONG_WAY_COUNTS) || (along_r < -WRONG_WAY_COUNTS);
    wire reverse_stalled = (idle_l_ms >= REVERSE_STALL_MS) || (idle_r_ms >= REVERSE_STALL_MS);
    wire reverse_over_limit = (straight_error > REVERSE_DRIFT_LIMIT) ||
                              (straight_error < -REVERSE_DRIFT_LIMIT) ||
                              (elapsed_ms >= REVERSE_LIMIT_MS);
    wire qualifying = ((state == EXIT_STRAIGHT) && (exit_armed ? line_seen : !line_seen)) ||
                      ((state == EXIT_TURN) && (pivot_yaw >= RETURN_MIN) && line_centered) ||
                      ((state == FOLLOW) && !line_valid);

    assign active = run_enable && (state != IDLE) && (state != FAULT);
    assign following = active && (state == FOLLOW);
    assign stopped = (state == FAULT);

    always @(*) begin
        next_state = state;
        if (!run_enable) begin
            next_state = IDLE;
        end else begin
            case (state)
                IDLE: next_state = DELAY;
                DELAY: if (elapsed_ms >= START_MS) next_state = ENTRY_TURN;
                ENTRY_TURN: begin
                    if (pivot_failed) next_state = FAULT;
                    else if (pivot_yaw >= TURN_COUNTS) next_state = ENTRY_BRAKE;
                end
                ENTRY_BRAKE: if (elapsed_ms >= BRAKE_MS) next_state = REVERSE;
                REVERSE: begin
                    if (reverse_wrong_way || reverse_stalled || reverse_over_limit) next_state = FAULT;
                    else if (reverse_done_l && reverse_done_r) next_state = PARKED;
                end
                PARKED: if (elapsed_ms >= PARK_MS + BRAKE_MS) next_state = EXIT_STRAIGHT;
                EXIT_STRAIGHT: begin
                    if (straight_failed) next_state = FAULT;
                    else if (exit_armed && line_seen && hold_ms >= LINE_MS) next_state = EXIT_BRAKE;
                    else if (elapsed_ms >= EXIT_LIMIT_MS || sum_along >= 2 * EXIT_COUNTS)
                        next_state = FAULT;
                end
                EXIT_BRAKE: if (elapsed_ms >= BRAKE_MS) next_state = EXIT_TURN;
                EXIT_TURN: begin
                    if (pivot_failed) next_state = FAULT;
                    else if (line_centered && hold_ms >= CENTER_MS) next_state = FOLLOW;
                    else if (pivot_yaw >= RETURN_MAX) next_state = FAULT;
                end
                FOLLOW: if (!line_valid && hold_ms >= LOST_MS) next_state = FAULT;
                FAULT: next_state = FAULT;
                default: next_state = IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tick_count <= 0;
            elapsed_ms <= 0;
            hold_ms <= 0;
            exit_armed <= 1'b0;
            start_l <= 0;
            start_r <= 0;
            fault <= 1'b0;
            reverse_fault <= REVERSE_OK;
        end else if (state != next_state) begin
            state <= next_state;
            tick_count <= 0;
            elapsed_ms <= 0;
            hold_ms <= 0;
            exit_armed <= 1'b0;
            start_l <= position_l;
            start_r <= position_r;
            if (next_state == FAULT) begin
                fault <= 1'b1;
                if (state == REVERSE) begin
                    if (reverse_wrong_way) reverse_fault <= REVERSE_WRONG_WAY;
                    else if (reverse_stalled) reverse_fault <= REVERSE_STALLED;
                    else reverse_fault <= REVERSE_LIMIT;
                end
            end else if (next_state == DELAY) begin
                fault <= 1'b0;
                reverse_fault <= REVERSE_OK;
            end
        end else begin
            tick_count <= ms_tick ? 0 : tick_count + 1'b1;
            if (ms_tick) begin
                if (elapsed_ms != 16'hffff)
                    elapsed_ms <= elapsed_ms + 1'b1;
                if (state == EXIT_STRAIGHT && !exit_armed && !line_seen &&
                    hold_ms == CLEAR_MS - 1) begin
                    exit_armed <= 1'b1;
                    hold_ms <= 0;
                end else if (!qualifying) begin
                    hold_ms <= 0;
                end else if (hold_ms != 8'hff) begin
                    hold_ms <= hold_ms + 1'b1;
                end
            end
        end
    end

    // 倒车起步时先约束领先轮。只有被要求转动却一直没有净进度的轮才判堵转。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pause_l <= 1'b0;
            pause_r <= 1'b0;
            idle_l_ms <= 0;
            idle_r_ms <= 0;
            last_progress_l <= 0;
            last_progress_r <= 0;
        end else if (state != REVERSE || next_state != REVERSE) begin
            pause_l <= 1'b0;
            pause_r <= 1'b0;
            idle_l_ms <= 0;
            idle_r_ms <= 0;
            last_progress_l <= 0;
            last_progress_r <= 0;
        end else if (ms_tick) begin
            pause_l <= (straight_error >= (pause_l ? RESUME_GAP : CATCH_GAP));
            pause_r <= (straight_error <= -(pause_r ? RESUME_GAP : CATCH_GAP));

            if (brake_l || along_l - last_progress_l >= PROGRESS_COUNTS) begin
                idle_l_ms <= 0;
                last_progress_l <= along_l;
            end else if (idle_l_ms < REVERSE_STALL_MS) begin
                idle_l_ms <= idle_l_ms + 1'b1;
            end
            if (brake_r || along_r - last_progress_r >= PROGRESS_COUNTS) begin
                idle_r_ms <= 0;
                last_progress_r <= along_r;
            end else if (idle_r_ms < REVERSE_STALL_MS) begin
                idle_r_ms <= idle_r_ms + 1'b1;
            end
        end
    end

    // active 期间占空比为 0 的轮走短刹。停车与换向等待均不施加驱动。
    always @(*) begin
        status = 3'd0;
        forward_l = 1'b1;
        forward_r = 1'b1;
        duty_l = 11'd0;
        duty_r = 11'd0;
        if (active) begin
            case (state)
                DELAY: status = 3'd1;
                ENTRY_TURN: begin
                    status = 3'd2;
                    forward_l = 1'b0;
                    duty_l = PIVOT_DUTY;
                end
                ENTRY_BRAKE: status = 3'd2;
                REVERSE: begin
                    status = 3'd3;
                    forward_l = 1'b0;
                    forward_r = 1'b0;
                    duty_l = brake_l ? 11'd0 : (pause_r ? CATCH_DUTY : straight_l[10:0]);
                    duty_r = brake_r ? 11'd0 : (pause_l ? CATCH_DUTY : straight_r[10:0]);
                end
                PARKED: status = 3'd4;
                EXIT_STRAIGHT: begin
                    status = 3'd5;
                    duty_l = straight_l[10:0];
                    duty_r = straight_r[10:0];
                end
                EXIT_BRAKE: status = 3'd5;
                EXIT_TURN: begin
                    status = 3'd6;
                    duty_l = PIVOT_DUTY;
                end
                FOLLOW: begin
                    status = 3'd7;
                    duty_l = (follow_duty_l > FOLLOW_MAX_DUTY) ? FOLLOW_MAX_DUTY : follow_duty_l;
                    duty_r = (follow_duty_r > FOLLOW_MAX_DUTY) ? FOLLOW_MAX_DUTY : follow_duty_r;
                end
                default: begin end
            endcase
        end
    end
endmodule
