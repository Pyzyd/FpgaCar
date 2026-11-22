`timescale 1ns/1ns

module wheel_jog #(
    parameter integer DEBOUNCE_TICKS = 480_000,
    parameter integer MAX_PULSE_TICKS = 12_000_000
) (
    input wire clk, rst_n,
    input wire key_start_n, key_stop_n,
    output wire drive_l, drive_r
);
    localparam [1:0] RELEASED=2'b11, LEFT=2'b10, RIGHT=2'b01;
    localparam [1:0] WAIT_RELEASE=0, READY=1, RUN_LEFT=2, RUN_RIGHT=3;
    localparam integer DB_BITS = $clog2(DEBOUNCE_TICKS + 1);
    localparam integer PULSE_BITS = $clog2(MAX_PULSE_TICKS + 1);
    (* async_reg = "true" *) reg [1:0] key_meta, key_sync;
    reg [1:0] candidate, stable_keys, state;
    reg [DB_BITS-1:0] debounce_count;
    reg [PULSE_BITS-1:0] pulse_count;

    // A release or opposite key drops the enable at the synchronizer output;
    // only entry to a driven state waits for debounce.
    assign drive_l = rst_n && state == RUN_LEFT && key_sync == LEFT;
    assign drive_r = rst_n && state == RUN_RIGHT && key_sync == RIGHT;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 0;
            key_sync <= 0;
            candidate <= 0;
            stable_keys <= 0;
            debounce_count <= 0;
        end else begin
            key_meta <= {key_stop_n, key_start_n};
            key_sync <= key_meta;
            if (key_sync != candidate) begin
                candidate <= key_sync;
                debounce_count <= 0;
            end else if (debounce_count < DEBOUNCE_TICKS) begin
                debounce_count <= debounce_count + 1'b1;
                if (debounce_count == DEBOUNCE_TICKS-1)
                    stable_keys <= candidate;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_RELEASE;
            pulse_count <= 0;
        end else begin
            case (state)
                WAIT_RELEASE: if (stable_keys == RELEASED && key_sync == RELEASED)
                    state <= READY;
                READY: begin
                    pulse_count <= 0;
                    if (key_sync == 0)
                        state <= WAIT_RELEASE;
                    else if (stable_keys == key_sync) begin
                        if (stable_keys == LEFT) state <= RUN_LEFT;
                        if (stable_keys == RIGHT) state <= RUN_RIGHT;
                    end
                end
                RUN_LEFT, RUN_RIGHT: begin
                    if (!(drive_l || drive_r) || pulse_count == MAX_PULSE_TICKS-1)
                        state <= WAIT_RELEASE;
                    else
                        pulse_count <= pulse_count + 1'b1;
                end
                default: state <= WAIT_RELEASE;
            endcase
        end
    end
endmodule

module encoder_input_filter #(
    parameter integer STABLE_TICKS = 240
) (
    input wire clk, rst_n,
    input wire [1:0] raw,
    output reg [1:0] settled
);
    (* async_reg = "true" *) reg [1:0] meta, synced;
    reg [1:0] candidate;
    reg [$clog2(STABLE_TICKS+1)-1:0] age;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta <= 0;
            synced <= 0;
            candidate <= 0;
            settled <= 0;
            age <= 0;
        end else begin
            meta <= raw;
            synced <= meta;
            if (synced != candidate) begin
                candidate <= synced;
                age <= 0;
            end else if (age < STABLE_TICKS) begin
                age <= age + 1'b1;
                if (age == STABLE_TICKS-1)
                    settled <= candidate;
            end
        end
    end
endmodule
