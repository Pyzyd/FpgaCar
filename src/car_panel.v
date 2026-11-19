`timescale 1ns/1ns

module car_panel #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer CLEAR_MS = 1000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_start_n,
    input  wire       key_stop_n,
    input  wire       line_ready,
    input  wire       motion_stopped,
    output wire       run_enable,
    output reg        clear_result,
    output reg  [1:0] status
);
    localparam [1:0] READY = 2'd0, RUN = 2'd1, STOP = 2'd2, LINE = 2'd3;
    localparam integer MS_CYCLES = CLK_FREQ / 1000;
    localparam integer TICK_W = (MS_CYCLES <= 1) ? 1 : $clog2(MS_CYCLES);
    localparam integer DB_W = $clog2(DEBOUNCE_MS + 1);
    localparam integer HOLD_W = $clog2(CLEAR_MS + 1);

    reg [1:0] start_sync, stop_sync;
    reg [TICK_W-1:0] tick_count;
    reg [DB_W-1:0] start_count, stop_release_count;
    reg [HOLD_W-1:0] stop_hold_count;
    reg start_released;

    wire ms_tick = (tick_count == MS_CYCLES - 1);
    wire start_press = ms_tick && start_released && !start_sync[1] &&
                       (start_count == DEBOUNCE_MS - 1);
    wire stop_released = stop_sync[1] && (stop_release_count == DEBOUNCE_MS);
    wire clear_press = ms_tick && !stop_sync[1] && (stop_hold_count == CLEAR_MS - 1);

    // 停车直接用同步后的 K2，等消抖只用于释放。松开后仍需重新按 K1。
    assign run_enable = rst_n && (status == RUN) && stop_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_sync <= 2'b00;
            stop_sync <= 2'b00;
        end else begin
            start_sync <= {start_sync[0], key_start_n};
            stop_sync <= {stop_sync[0], key_stop_n};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_count <= 0;
            start_count <= 0;
            start_released <= 1'b0;
            stop_release_count <= 0;
            stop_hold_count <= 0;
            status <= READY;
            clear_result <= 1'b0;
        end else begin
            tick_count <= ms_tick ? 0 : tick_count + 1'b1;
            clear_result <= clear_press;

            if (ms_tick) begin
                if (start_sync[1] == start_released) begin
                    start_count <= 0;
                end else if (start_count == DEBOUNCE_MS - 1) begin
                    start_released <= start_sync[1];
                    start_count <= 0;
                end else begin
                    start_count <= start_count + 1'b1;
                end

                if (stop_sync[1]) begin
                    stop_hold_count <= 0;
                    if (stop_release_count != DEBOUNCE_MS)
                        stop_release_count <= stop_release_count + 1'b1;
                end else if (stop_hold_count != CLEAR_MS) begin
                    stop_hold_count <= stop_hold_count + 1'b1;
                end
            end
            if (!stop_sync[1])
                stop_release_count <= 0;

            if (clear_press)
                status <= READY;
            else if ((status == RUN && motion_stopped) ||
                     (!stop_sync[1] && (status == RUN || status == LINE)))
                status <= STOP;
            else if (start_press && stop_released && status != RUN)
                status <= line_ready ? RUN : LINE;
        end
    end
endmodule
