`timescale 1ns/1ns

// 10 cm 方块在直道中央。从右侧绕行，编码器统一为实际左右轮、前进计正。
module course_bypass #(
    parameter integer CLK_FREQ = 24_000_000
) (
    input  wire clk, rst_n, run_enable,
    input  wire request, entry_forward,
    input  wire obstacle, dist_valid,
    input  wire [15:0] dist_cm,
    input  wire line_seen, line_valid,
    input  wire signed [4:0] line_pos,
    input  wire signed [31:0] pos_l, pos_r,
    output wire owns_motors, drive,
    output wire fault, stop_request,
    output reg  [3:0] phase,
    output reg  [7:0] fault_info,
    output reg  [10:0] duty_l, duty_r
);
    localparam [3:0] IDLE = 0, APPROACH = 1, SETTLE = 2, OUT_RIGHT = 3,
                     ALIGN_LEFT = 4, PASS = 5, MERGE_LEFT = 6, ALIGN_RIGHT = 7,
                     FIND_LINE = 8, COMPLETE = 9, FAILED = 15;
    localparam integer MS_DIV = CLK_FREQ / 1000;
    localparam integer MS_W = (MS_DIV < 2) ? 1 : $clog2(MS_DIV);
    // 轮距 164 mm，64° 弧实际内外轮行程 91.6 / 274.8 mm。
    // 按 2532 计数/圈、周长 212 mm 换算。两轮按累计目标切换，跨段余转也纳入里程。
    localparam signed [31:0] INNER = 1094, OUTER = 3 * INNER, PAIR = INNER + OUTER;
    localparam signed [31:0] COUNTS_PER_CM = 119;
    // 轴到车头 75 mm + 障碍半长 50 mm + 回线弧起点 105 mm - 出线弧前进 295 mm。
    localparam signed [31:0] PASS_OFFSET = 777; // 65 mm
    localparam signed [31:0] CLOSE_COUNTS = 20 * COUNTS_PER_CM;
    localparam signed [31:0] START_COUNTS = 23 * COUNTS_PER_CM;
    localparam signed [31:0] MIN_START_COUNTS = CLOSE_COUNTS - 59; // 最晚约 19.5 cm 起弧
    localparam integer REARM_COUNTS = 12 * COUNTS_PER_CM;
    localparam integer SETTLE_MS = 120, RANGE_AGE_MS = 250, APPROACH_MS = 1500;
    localparam integer STALL_MS = 850, PROGRESS = 8;
    localparam integer ARC_MS = 4200, PASS_MS = 3500, FIND_MS = 500;
    localparam signed [31:0] MAX_WHEEL_LEAD = 300, WRONG_WAY = 36;
    localparam signed [31:0] ALIGN_SLACK = 110, FIND_COUNTS = 155;
    localparam integer LOST_CONFIRM_MS = 24, CENTER_CONFIRM_MS = 35;
    localparam integer APPROACH_LOST_MS = 100;

    reg [MS_W-1:0] divider;
    wire tick_ms = divider == MS_DIV - 1;
    reg [12:0] elapsed;
    reg [7:0] line_ms;
    reg left_line;
    reg signed [31:0] base_l, base_r;
    reg signed [31:0] sample_l, sample_r;
    reg signed [31:0] pass_counts;
    reg [15:0] sample_cm;
    reg [8:0] range_age;
    reg [9:0] idle_l_ms, idle_r_ms;
    reg signed [31:0] progress_l, progress_r;
    reg [3:0] next_phase;
    reg run_prev;
    reg signed [4:0] last_line_pos;
    reg [6:0] line_gap_ms;

    wire fresh = (range_age < RANGE_AGE_MS) && (sample_cm <= 16'd40);
    wire signed [31:0] since_sample_l = pos_l - sample_l;
    wire signed [31:0] since_sample_r = pos_r - sample_r;
    wire signed [31:0] since_sample = (since_sample_l + since_sample_r) >>> 1;
    wire signed [31:0] range_counts = $signed({1'b0, sample_cm[5:0]}) * COUNTS_PER_CM
                                      - since_sample;
    wire signed [31:0] traveled_l = pos_l - base_l;
    wire signed [31:0] traveled_r = pos_r - base_r;
    wire signed [31:0] heading_counts = traveled_l - traveled_r;
    wire centered = line_valid && line_pos >= -5'sd2 && line_pos <= 5'sd2;
    wire angled = (phase == OUT_RIGHT || phase == ALIGN_LEFT ||
                   phase == MERGE_LEFT || phase == ALIGN_RIGHT);
    wire left_outer = (phase == OUT_RIGHT || phase == ALIGN_RIGHT);
    wire route = angled || phase == PASS;
    wire moving_phase = route || phase == APPROACH || phase == FIND_LINE;
    wire route_timeout = elapsed >= (phase == PASS ? PASS_MS : ARC_MS);
    wire wheel_stalled = (idle_l_ms >= STALL_MS) || (idle_r_ms >= STALL_MS);
    wire wrong_way = (pos_l - progress_l < -WRONG_WAY) ||
                     (pos_r - progress_r < -WRONG_WAY);
    wire signed [4:0] approach_pos = line_valid ? line_pos : last_line_pos;
    wire entry_aligned = entry_forward && (line_gap_ms < APPROACH_LOST_MS) &&
                         (approach_pos >= -5'sd3) && (approach_pos <= 5'sd3);
    wire approach_lost = !line_valid && line_gap_ms >= APPROACH_LOST_MS;
    wire [10:0] approach_l = (approach_pos > 5'sd1) ? 11'd280 :
                             (approach_pos < -5'sd1) ? 11'd232 : 11'd256;
    wire [10:0] approach_r = (approach_pos < -5'sd1) ? 11'd280 :
                             (approach_pos > 5'sd1) ? 11'd232 : 11'd256;

    reg signed [31:0] target_l, target_r;
    reg signed [31:0] begin_l, begin_r;
    wire signed [31:0] pass_end = PAIR + pass_counts;
    always @(*) begin
        case (phase)
            OUT_RIGHT:   begin begin_l = 0;                begin_r = 0;
                               target_l = OUTER;           target_r = INNER; end
            ALIGN_LEFT:  begin begin_l = OUTER;            begin_r = INNER;
                               target_l = PAIR;            target_r = PAIR; end
            PASS:        begin begin_l = PAIR;             begin_r = PAIR;
                               target_l = pass_end;        target_r = pass_end; end
            MERGE_LEFT:  begin begin_l = pass_end;         begin_r = pass_end;
                               target_l = pass_end+INNER;  target_r = pass_end+OUTER; end
            default:     begin begin_l = pass_end+INNER;   begin_r = pass_end+OUTER;
                               target_l = pass_end+PAIR;   target_r = pass_end+PAIR; end
        endcase
    end

    wire signed [31:0] leg_l = traveled_l - begin_l;
    wire signed [31:0] leg_r = traveled_r - begin_r;
    // 角度段按外轮:内轮=3:1 纠偏，直段直接比较两轮位移。
    wire signed [31:0] error = !angled ? leg_l - leg_r :
                               left_outer ? leg_l - 3 * leg_r : 3 * leg_l - leg_r;
    wire signed [31:0] trim_unclamped = error / 4;
    wire signed [31:0] trim = (trim_unclamped > 72) ? 32'sd72 :
                              (trim_unclamped < -72) ? -32'sd72 : trim_unclamped;
    wire signed [11:0] base_duty_l = !angled ? 12'sd300 : left_outer ? 12'sd420 : 12'sd276;
    wire signed [11:0] base_duty_r = !angled ? 12'sd300 : left_outer ? 12'sd276 : 12'sd420;
    wire signed [11:0] demand_l = base_duty_l - $signed(trim[11:0]);
    wire signed [11:0] demand_r = base_duty_r + $signed(trim[11:0]);
    wire reached_l = (traveled_l >= target_l);
    wire reached_r = (traveled_r >= target_r);
    wire route_clear = (heading_counts >= -ALIGN_SLACK) && (heading_counts <= ALIGN_SLACK);
    wire line_qualified = centered && route_clear;
    reg [3:0] fault_code;
    always @(*) begin
        if (moving_phase && wrong_way) fault_code = 4'd1;
        else if (moving_phase && idle_l_ms >= STALL_MS) fault_code = 4'd2;
        else if (moving_phase && idle_r_ms >= STALL_MS) fault_code = 4'd3;
        else begin
            case (phase)
                IDLE: fault_code = 4'd4;
                APPROACH, SETTLE: begin
                    if (!fresh) fault_code = 4'd5;
                    else if ((phase == APPROACH && approach_lost) ||
                             (phase == SETTLE && !line_valid)) fault_code = 4'd6;
                    else if (range_counts < MIN_START_COUNTS ||
                             (phase == SETTLE && range_counts > START_COUNTS + 59))
                        fault_code = 4'd7;
                    else fault_code = 4'd8;
                end
                PASS: fault_code = route_timeout ? 4'd8 : 4'd9;
                FIND_LINE: fault_code = 4'd10;
                default: fault_code = 4'd8;
            endcase
        end
    end

    assign fault = (phase == FAILED);
    assign stop_request = fault && run_prev;
    assign owns_motors = run_enable && (phase != IDLE && phase != COMPLETE);
    // 短刹期及先到目标的车轮使用 PWM=0；STBY 要保持使能。
    assign drive = owns_motors && !fault;

    always @(*) begin
        duty_l = 0;
        duty_r = 0;
        if (drive && route) begin
            if (!reached_l && (reached_r || error <= MAX_WHEEL_LEAD)) duty_l = demand_l[10:0];
            if (!reached_r && (reached_l || error >= -MAX_WHEEL_LEAD)) duty_r = demand_r[10:0];
        end else if (drive && phase == APPROACH && fresh &&
                     range_counts > START_COUNTS && !approach_lost) begin
            duty_l = approach_l;
            duty_r = approach_r;
        end else if (drive && phase == FIND_LINE && !line_qualified) begin
            duty_l = line_valid ? approach_l : 11'd256;
            duty_r = line_valid ? approach_r : 11'd256;
        end
    end

    always @(*) begin
        next_phase = phase;
        if (run_enable) begin
            case (phase)
                IDLE: if (request) next_phase = entry_aligned ? APPROACH : FAILED;
                FAILED: if (!run_prev) next_phase = IDLE;
                APPROACH: begin
                    if (!fresh || approach_lost || elapsed >= APPROACH_MS ||
                        range_counts < MIN_START_COUNTS) next_phase = FAILED;
                    else if (range_counts <= START_COUNTS) next_phase = SETTLE;
                end
                SETTLE: if (elapsed >= SETTLE_MS)
                    next_phase = (fresh && range_counts >= MIN_START_COUNTS &&
                                  line_valid && range_counts <= START_COUNTS + 59)
                                 ? OUT_RIGHT : FAILED;
                OUT_RIGHT, ALIGN_LEFT, PASS, MERGE_LEFT, ALIGN_RIGHT: begin
                    if (route_timeout) next_phase = FAILED;
                    else if (reached_l && reached_r) begin
                        case (phase)
                            OUT_RIGHT: next_phase = ALIGN_LEFT;
                            ALIGN_LEFT: next_phase = PASS;
                            PASS: next_phase = (left_line && route_clear) ? MERGE_LEFT : FAILED;
                            MERGE_LEFT: next_phase = ALIGN_RIGHT;
                            ALIGN_RIGHT: next_phase = FIND_LINE;
                            default: next_phase = FAILED;
                        endcase
                    end
                end
                FIND_LINE: begin
                    if (line_qualified && line_ms >= CENTER_CONFIRM_MS) next_phase = COMPLETE;
                    else if (elapsed >= FIND_MS ||
                             traveled_l + traveled_r >= 2 * (pass_end + PAIR + FIND_COUNTS))
                        next_phase = FAILED;
                end
                COMPLETE: if (!obstacle && traveled_l + traveled_r >=
                             2 * (pass_end + PAIR + REARM_COUNTS))
                    next_phase = IDLE;
                default: next_phase = FAILED;
            endcase
            if (moving_phase && (wheel_stalled || wrong_way)) next_phase = FAILED;
        end else if (!fault) begin
            next_phase = IDLE;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= IDLE;
            divider <= 0;
            elapsed <= 0;
            line_ms <= 0;
            left_line <= 0;
            base_l <= 0;
            base_r <= 0;
            sample_l <= 0;
            sample_r <= 0;
            sample_cm <= 16'hffff;
            range_age <= 9'h1ff;
            pass_counts <= 0;
            idle_l_ms <= 0;
            idle_r_ms <= 0;
            progress_l <= 0;
            progress_r <= 0;
            run_prev <= 0;
            fault_info <= 0;
            last_line_pos <= 0;
            line_gap_ms <= 7'h7f;
        end else begin
            phase <= next_phase;
            run_prev <= run_enable;
            if (phase != FAILED && next_phase == FAILED) fault_info <= {phase, fault_code};
            else if (!run_prev && run_enable) fault_info <= 0;
            divider <= tick_ms ? 0 : divider + 1'b1;
            if (line_valid) begin
                last_line_pos <= line_pos;
                line_gap_ms <= 0;
            end else if (tick_ms && line_gap_ms != 7'h7f) begin
                line_gap_ms <= line_gap_ms + 1'b1;
            end
            if (dist_valid && dist_cm != 16'hffff) begin
                sample_cm <= dist_cm;
                sample_l <= pos_l;
                sample_r <= pos_r;
                range_age <= 0;
            end else if (tick_ms && range_age != 9'h1ff) begin
                range_age <= range_age + 1'b1;
            end
            if (phase != next_phase) begin
                elapsed <= 0;
                line_ms <= 0;
                idle_l_ms <= 0;
                idle_r_ms <= 0;
                progress_l <= pos_l;
                progress_r <= pos_r;
                if (phase == IDLE) left_line <= 0;
                if (next_phase == OUT_RIGHT) begin
                    base_l <= pos_l;
                    base_r <= pos_r;
                    pass_counts <= range_counts - PASS_OFFSET;
                end
            end else if (tick_ms) begin
                if (elapsed != 13'h1fff) elapsed <= elapsed + 1'b1;
                if ((route && !line_seen) || (phase == FIND_LINE && line_qualified)) begin
                    if (line_ms != 8'hff) line_ms <= line_ms + 1'b1;
                end else begin
                    line_ms <= 0;
                end
                if (route && !line_seen && line_ms >= LOST_CONFIRM_MS - 1) left_line <= 1;
                if (duty_l == 0 || pos_l - progress_l >= PROGRESS) begin
                    progress_l <= pos_l;
                    idle_l_ms <= 0;
                end else if (idle_l_ms < STALL_MS) idle_l_ms <= idle_l_ms + 1'b1;
                if (duty_r == 0 || pos_r - progress_r >= PROGRESS) begin
                    progress_r <= pos_r;
                    idle_r_ms <= 0;
                end else if (idle_r_ms < STALL_MS) idle_r_ms <= idle_r_ms + 1'b1;
            end
        end
    end
endmodule
