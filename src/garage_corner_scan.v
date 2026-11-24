`timescale 1ns/1ns

// 读取一张锁定的 320x180 灰度图，寻找同一条横向胶带的两个转角。
module garage_corner_scan (
    input  wire clk, rst_n, frame_valid,
    input  wire [7:0] read_y,
    output wire [15:0] read_addr,
    output reg  frame_release, frame_done, corner_seen, pair_valid,
    output reg  [9:0] center_x_sum
);
    localparam [3:0] WAIT_FRAME=0, CENTER=1, H_NEAR=2, H_FAR=3, H_OUT=4,
                     LEG_NEAR=5, LEG_FAR=6, SCORE=7, NEXT_PIXEL=8,
                     CHECK_PAIR=9, CHECK_TAPE=10, REPORT=11;
    localparam integer CORNER_SCORE = 100;
    reg [3:0] state;
    // 保留符号位，防止边缘外的采样坐标绕回另一侧。
    reg signed [10:0] x, y;
    reg right_side;
    reg signed [5:0] offset;
    reg [7:0] center_h, contrast_max, inner_h, outside_h, leg_near, best_leg;
    reg [9:0] best_left, best_right, best_any;
    reg [8:0] left_x, right_x;
    reg [7:0] left_y, right_y;
    reg [1:0] tape_section, tape_hits;
    reg pair_ok;

    wire signed [10:0] inward = right_side ? -11'sd1 : 11'sd1;
    wire signed [10:0] leg_dx = {{5{offset[5]}}, offset};
    wire signed [5:0] slope_end = right_side ? 6'sd14 : 6'sd0;
    wire signed [10:0] width = {2'b0, right_x} - {2'b0, left_x};
    wire signed [10:0] height_diff = {3'b0, right_y} - {3'b0, left_y};
    wire signed [10:0] center_y_sum = {3'b0, left_y} + {3'b0, right_y};
    wire signed [10:0] tape_x =
        {2'b0, left_x} + (tape_section == 0 ? (width >>> 2) :
                         tape_section == 1 ? (width >>> 1) :
                         width - (width >>> 2));
    wire signed [10:0] tape_y =
        {3'b0, left_y} + (tape_section == 0 ? (height_diff >>> 2) :
                         tape_section == 1 ? (height_diff >>> 1) :
                         height_diff - (height_diff >>> 2));

    reg signed [10:0] test_x, test_y;
    reg vertical;
    always @(*) begin
        test_x = x;
        test_y = y;
        vertical = 0;
        case (state)
            H_NEAR, H_FAR, H_OUT: begin
                case (state)
                    H_NEAR: test_x = x + 7 * inward;
                    H_FAR:  test_x = x + 15 * inward;
                    default: test_x = x - 9 * inward;
                endcase
                test_y = y + leg_dx;
            end
            LEG_NEAR, LEG_FAR: begin
                vertical = 1;
                test_x = x + (state == LEG_NEAR ? leg_dx : (leg_dx <<< 1));
                test_y = y + (state == LEG_NEAR ? 11'sd5 : 11'sd10);
            end
            CHECK_TAPE: begin
                test_x = tape_x;
                test_y = tape_y + leg_dx;
            end
            default: begin end
        endcase
    end

    // 单端口同步读。依次采中心、两侧背景，粗侧边还用中心两邻点抑制细地砖缝。
    reg [2:0] tap;
    reg [7:0] p0, p1, p2, p3;
    reg signed [10:0] tap_x, tap_y;
    wire readable = test_x >= (vertical ? 9 : 0) && test_x < (vertical ? 311 : 320) &&
                    test_y >= (vertical ? 0 : 3) && test_y < (vertical ? 180 : 177);
    wire probing = (state >= CENTER && state <= LEG_FAR) || state == CHECK_TAPE;
    always @(*) begin
        tap_x = test_x;
        tap_y = test_y;
        case (tap)
            1: if (vertical) tap_x = test_x - 9; else tap_y = test_y - 3;
            2: if (vertical) tap_x = test_x + 9; else tap_y = test_y + 3;
            3: tap_x = test_x - 1;
            4: tap_x = test_x + 1;
            default: begin end
        endcase
    end
    wire [15:0] row_addr = ({8'b0, tap_y[7:0]} << 8) + ({8'b0, tap_y[7:0]} << 6);
    assign read_addr = probing && readable ? row_addr + {7'b0, tap_x[8:0]} : 16'd0;
    wire sample_done = probing && (!readable || tap == (vertical ? 3'd5 : 3'd3));
    wire [8:0] h_bg = {1'b0,p1} + {1'b0,read_y};
    wire [8:0] v_bg = {1'b0,p1} + {1'b0,p2};
    wire [8:0] inner_pair = {1'b0,p3} + {1'b0,read_y};
    wire [7:0] v_inside = p0 > inner_pair[8:1] ? p0 : inner_pair[8:1];
    wire [7:0] bg = vertical ? v_bg[8:1] : h_bg[8:1];
    wire [7:0] foreground = vertical ? v_inside : p0;
    wire [7:0] contrast = readable && bg > foreground ? bg - foreground : 8'd0;
    wire [7:0] peak = contrast > contrast_max ? contrast : contrast_max;
    wire [7:0] leg_support = contrast < leg_near ? contrast : leg_near;
    wire [7:0] joint = best_leg < inner_h ? best_leg : inner_h;
    wire [9:0] raw_score = 3 * {2'b0,joint} + {2'b0,center_h};
    wire [9:0] score = (best_leg >= 12 && raw_score > {2'b0,outside_h}) ?
                        raw_score - {2'b0,outside_h} : 10'd0;
    wire plausible_pair = best_left >= CORNER_SCORE && best_right >= CORNER_SCORE &&
                          width >= 245 && width <= 290 &&
                          center_y_sum >= 177 && center_y_sum <= 302 &&
                          height_diff >= -11'sd8 && height_diff <= 11'sd37;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tap <= 0;
            p0 <= 0; p1 <= 0; p2 <= 0; p3 <= 0;
        end else if (!probing || sample_done) begin
            tap <= 0;
        end else begin
            tap <= tap + 1'b1;
            case (tap)
                1: p0 <= read_y;
                2: p1 <= read_y;
                3: p2 <= read_y;
                4: p3 <= read_y;
                default: begin end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_FRAME;
            x <= 0; y <= 0;
            right_side <= 0; offset <= 0;
            center_h <= 0; contrast_max <= 0; inner_h <= 0; outside_h <= 0;
            leg_near <= 0; best_leg <= 0;
            best_left <= 0; best_right <= 0; best_any <= 0;
            left_x <= 0; left_y <= 0; right_x <= 0; right_y <= 0;
            tape_section <= 0; tape_hits <= 0; pair_ok <= 0;
            frame_release <= 0; frame_done <= 0;
            corner_seen <= 0; pair_valid <= 0; center_x_sum <= 0;
        end else begin
            frame_release <= 0;
            frame_done <= 0;
            case (state)
                WAIT_FRAME: if (frame_valid && !frame_release) begin
                    x <= 8; y <= 76;
                    best_left <= 0; best_right <= 0; best_any <= 0;
                    right_side <= 0; pair_ok <= 0;
                    state <= CENTER;
                end
                CENTER: if (sample_done) begin
                    center_h <= contrast;
                    offset <= -6'sd1;
                    contrast_max <= 0;
                    state <= contrast >= 5 ? H_NEAR : NEXT_PIXEL;
                end
                H_NEAR, H_FAR, H_OUT: if (sample_done) begin
                    contrast_max <= peak;
                    offset <= offset + 1'b1;
                    case (state)
                        H_NEAR: if (offset == 2) begin
                            inner_h <= peak;
                            contrast_max <= 0; offset <= -6'sd3;
                            state <= peak >= 10 ? H_FAR : SCORE;
                            best_leg <= 0;
                        end
                        H_FAR: if (offset == 3) begin
                            inner_h <= peak < inner_h ? peak : inner_h;
                            contrast_max <= 0; offset <= -6'sd2;
                            state <= peak >= 10 ? H_OUT : SCORE;
                        end
                        default: if (offset == 2) begin
                            outside_h <= peak;
                            best_leg <= 0;
                            offset <= right_side ? -6'sd4 : -6'sd12;
                            state <= LEG_NEAR;
                        end
                    endcase
                end
                LEG_NEAR: if (sample_done) begin
                    if (contrast >= 12) begin
                        leg_near <= contrast;
                        state <= LEG_FAR;
                    end else if (offset == slope_end) state <= SCORE;
                    else offset <= offset + 1'b1;
                end
                LEG_FAR: if (sample_done) begin
                    if (leg_support > best_leg) best_leg <= leg_support;
                    if (offset == slope_end) state <= SCORE;
                    else begin
                        offset <= offset + 1'b1;
                        state <= LEG_NEAR;
                    end
                end
                SCORE: begin
                    if (score > best_any) best_any <= score;
                    if (!right_side && x <= 80 && score > best_left) begin
                        best_left <= score;
                        left_x <= x[8:0]; left_y <= y[7:0];
                    end
                    if (right_side && x >= 239 && score > best_right) begin
                        best_right <= score;
                        right_x <= x[8:0]; right_y <= y[7:0];
                    end
                    if (!right_side) begin
                        right_side <= 1;
                        offset <= -6'sd1;
                        contrast_max <= 0;
                        state <= H_NEAR;
                    end else state <= NEXT_PIXEL;
                end
                NEXT_PIXEL: begin
                    right_side <= 0;
                    if (x == 311 && y == 160) state <= CHECK_PAIR;
                    else begin
                        if (x == 311) begin x <= 8; y <= y + 1'b1; end
                        else x <= x + 1'b1;
                        state <= CENTER;
                    end
                end
                CHECK_PAIR: begin
                    tape_section <= 0; tape_hits <= 0;
                    offset <= -6'sd4; contrast_max <= 0;
                    state <= plausible_pair ? CHECK_TAPE : REPORT;
                end
                CHECK_TAPE: if (sample_done) begin
                    contrast_max <= peak;
                    offset <= offset + 1'b1;
                    if (offset == 4) begin
                        if (peak >= 9) tape_hits <= tape_hits + 1'b1;
                        if (tape_section == 2) begin
                            pair_ok <= tape_hits >= 2 || (tape_hits == 1 && peak >= 9);
                            state <= REPORT;
                        end else begin
                            tape_section <= tape_section + 1'b1;
                            offset <= -6'sd4; contrast_max <= 0;
                        end
                    end
                end
                REPORT: begin
                    corner_seen <= best_any >= CORNER_SCORE;
                    pair_valid <= pair_ok;
                    center_x_sum <= {1'b0,left_x} + {1'b0,right_x};
                    frame_done <= 1;
                    frame_release <= 1;
                    state <= WAIT_FRAME;
                end
                default: state <= WAIT_FRAME;
            endcase
        end
    end
endmodule
