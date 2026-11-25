`timescale 1ns/1ns

module parking_handoff_tb;
    reg clk = 0;
    always #5 clk = !clk;

    reg k1 = 1, k2 = 1;
    reg seen_line = 1, lost_line = 0, wide_line = 0;
    reg [3:0] line_count = 2;
    reg [2:0] k_data = 0;
    reg k_stb = 0;
    reg [31:0] raw_l = 0, raw_r = 0;
    wire stand_by, pwm_a, pwm_b;
    wire [1:0] in_a, in_b;
    wire hc_trig;

    FpgaCar dut (
        .clk(clk), .key_start_n(k1), .key_stop_n(k2), .track(8'hff),
        .hc_echo(1'b0), .hc_trig(hc_trig), .ir_l(1'b1), .ir_r(1'b1),
        .i2c_sda_IN(1'b1), .cmos_pclk(1'b0), .cmos_href(1'b0), .cmos_vsync(1'b0),
        .cmos_data(8'h00), .cmos_sdat_IN(1'b1), .enc_la(1'b0), .enc_lb(1'b0),
        .enc_ra(1'b0), .enc_rb(1'b0), .k230_d(k_data), .k230_stb(k_stb), .uart_rx(1'b1),
        .motor_stby(stand_by), .ml_pwm(pwm_a), .mr_pwm(pwm_b),
        .ml_in1(in_a[1]), .ml_in2(in_a[0]), .mr_in1(in_b[1]), .mr_in2(in_b[0])
    );

    localparam [10:0] RAW_DUTY_L = 400, RAW_DUTY_R = 500;
    wire [10:0] normal_l = RAW_DUTY_L * dut.TRACK_SPEED_PERCENT / 100;
    wire [10:0] normal_r = RAW_DUTY_R * dut.TRACK_SPEED_PERCENT / 100;

    task clocks(input integer count);
        repeat (count) @(negedge clk);
    endtask

    task check(input condition, input [8*90-1:0] description);
        begin
            if (condition !== 1'b1)
                $fatal(1, "FAIL: %0s (motion=%d panel=%d)", description,
                       dut.parking_status, dut.panel_status);
            $display("PASS: %0s", description);
        end
    endtask

    task press_start;
        begin
            k1 = 0;
            clocks(25);
            k1 = 1;
            clocks(25);
        end
    endtask

    task centered_frame;
        begin
            force dut.parking_frame_done = 1'b1;
            clocks(1);
            force dut.parking_frame_done = 1'b0;
            clocks(1);
        end
    endtask

    task symbol(input [2:0] value);
        begin
            k_data = value;
            clocks(4);
            k_stb = 1;
            clocks(4);
            k_stb = 0;
            clocks(4);
        end
    endtask

    task parking_packet;
        begin
            symbol(0); symbol(3); symbol(0); symbol(3); symbol(0);
        end
    endtask

    task start_parking;
        begin
            parking_packet();
            parking_packet();
            centered_frame();
            check(!dut.parking_brake && !dut.parking_owner, "one centered frame cannot take the motors");
            centered_frame();
            check(dut.parking_brake && !dut.parking_owner && stand_by &&
                  in_a == 2'b11 && in_b == 2'b11, "vision short-brakes both wheels before handoff");
            force dut.g_parking.approach.brake_timer = 22'd3599999;
            clocks(2);
            release dut.g_parking.approach.brake_timer;
            check(dut.parking_owner && dut.parking_status == 1 && dut.panel_status == 1 &&
                  stand_by && in_a == 2'b11 && in_b == 2'b11,
                  "visual brake keeps panel running and transfers to parking delay");
            clocks(2001);
            check(dut.parking_status == 2 && in_a == 2'b11 && in_b == 2'b10 &&
                  dut.ml_duty == 0 && dut.mr_duty == 300,
                  "entry pivot commands only physical left wheel backward");
        end
    endtask

    initial begin
        force dut.u_panel.ms_tick = 1'b1;
        force dut.u_car.ms_tick = 1'b1;
        force dut.u_finish.ms_tick = 1'b1;
        force dut.g_parking.action.ms_tick = 1'b1;
        force dut.parking_video_ready = 1'b1;
        force dut.parking_frame_done = 1'b0;
        force dut.parking_corner = 1'b1;
        force dut.parking_pair = 1'b1;
        force dut.g_parking.center_x_sum = 10'd320;
        force dut.line_on = seen_line;
        force dut.line_lost = lost_line;
        force dut.line_wide = wide_line;
        force dut.line_cnt = line_count;
        force dut.line_pos = 5'sd0;
        force dut.enc_l_pos = raw_l;
        force dut.enc_r_pos = raw_r;

        clocks(30);
        check(!stand_by && dut.USE_ULTRA && dut.USE_K230, "field power-on waits for K1 with K230 and sonar enabled");
        wide_line = 1; seen_line = 0; lost_line = 1; line_count = 8;
        press_start();
        check(dut.panel_status == 1 && dut.start_box_override && !dut.finish_owner,
              "starting on the box crosses wide black and cannot trigger the finish");
        wide_line = 0; seen_line = 1; lost_line = 0; line_count = 2;
        clocks(10);
        centered_frame();
        centered_frame();
        check(!dut.parking_brake && !dut.parking_owner, "camera cannot arm parking without a K230 P packet");
        parking_packet();
        check(!dut.g_parking.approach.armed, "one P packet cannot arm the receiver");
        // Complete the two matching packets and evaluate the initial approach scaling.
        parking_packet();
        force dut.raw_track_duty_l = RAW_DUTY_L;
        force dut.raw_track_duty_r = RAW_DUTY_R;
        clocks(2);
        check(dut.final_duty_l == normal_l * dut.PARK_AFTER_P_PERCENT / 100 &&
              dut.final_duty_r == normal_r * dut.PARK_AFTER_P_PERCENT / 100,
              "confirmed parking packet scales both tracking duties");
        force dut.parking_pair = 1'b0;
        centered_frame();
        check(dut.parking_slow && dut.final_duty_l == normal_l * dut.PARK_AFTER_CORNER_PERCENT / 100 &&
              dut.final_duty_r == normal_r * dut.PARK_AFTER_CORNER_PERCENT / 100,
              "a detected corner selects the corner speed ratio");
        release dut.raw_track_duty_l;
        release dut.raw_track_duty_r;
        force dut.parking_pair = 1'b1;
        start_parking();

        // 物理左轮后转时原始计数上升，动作模块入口使用前进为正。
        raw_l = 2940;
        clocks(2);
        check(dut.parking_status == 2 && dut.mr_duty == 0, "raw encoder sign reaches the entry brake threshold");
        raw_l = 3077;
        clocks(151);
        check(dut.parking_status == 3 && in_a == 2'b10 && in_b == 2'b10 &&
              dut.ml_duty != 0 && dut.mr_duty != 0, "both physical wheels drive backward");
        raw_l = 3077 + 3583;
        raw_r = 3583;
        clocks(2);
        check(dut.parking_status == 4 && stand_by && in_a == 2'b11 && in_b == 2'b11,
              "both 30 cm thresholds short-brake in the bay");
        seen_line = 0;
        lost_line = 1;
        clocks(5000);
        check(dut.parking_status == 4 && dut.ml_duty == 0 && dut.mr_duty == 0,
              "stopped through the full parking time");
        clocks(151);
        check(dut.parking_status == 5 && in_a == 2'b01 && in_b == 2'b01,
              "exit goes straight forward before seeing the main line");
        raw_l = raw_l - 2500;
        raw_r = raw_r - 2500;
        clocks(32);
        seen_line = 1;
        lost_line = 0;
        clocks(165);
        check(dut.parking_status == 6 && in_a == 2'b11 && in_b == 2'b01,
              "exit line starts the single-left-wheel right pivot");
        raw_l = raw_l - 3000;
        clocks(35);
        force dut.raw_track_duty_l = RAW_DUTY_L;
        force dut.raw_track_duty_r = RAW_DUTY_R;
        clocks(2);
        check(dut.parking_done && !dut.parking_owner && dut.car_state == 1 &&
              dut.final_duty_l == normal_l * dut.POST_PARK_PERCENT / 100 &&
              dut.final_duty_r == normal_r * dut.POST_PARK_PERCENT / 100,
              "centered exit hands the PWM back to slow tracking");
        release dut.raw_track_duty_l;
        release dut.raw_track_duty_r;
        centered_frame();
        centered_frame();
        check(!dut.parking_owner && !dut.parking_brake, "same run cannot trigger parking a second time");

        wide_line = 1; line_count = 8;
        clocks(3);
        wide_line = 0; line_count = 2;
        clocks(2);
        check(!dut.finish_owner, "a transient wide reading cannot trigger the finish");
        wide_line = 1; line_count = 8;
        clocks(10);
        check(dut.finish_driving && stand_by && in_a == 2'b01 && in_b == 2'b01,
              "the post-parking finish bar takes both wheels forward");
        raw_l = raw_l - 3583;
        raw_r = raw_r - 3582;
        clocks(3);
        check(dut.finish_driving && !dut.finish_braking, "finish remains moving just below 30 cm average");
        raw_r = raw_r - 1;
        clocks(3);
        check(dut.finish_braking && stand_by && in_a == 2'b11 && in_b == 2'b11,
              "30 cm average triggers active braking on both wheels");
        clocks(156);
        check(!stand_by && dut.panel_status == 2, "finish brakes then latches panel STOP");
        wide_line = 0; line_count = 2;

        k2 = 0;
        clocks(4);
        k2 = 1;
        clocks(30);
        press_start();
        start_parking();
        clocks(180);
        check(dut.mr_duty == 360 && dut.ml_duty == 0 && in_a == 2'b11,
              "entry stall boosts only physical left wheel and holds the right brake");
        k2 = 0;
        clocks(4);
        check({stand_by, pwm_a, pwm_b, in_a, in_b} == 0 && dut.panel_status == 2,
              "K2 cuts both physical motor outputs during boosted autonomous pivot");
        k2 = 1;
        clocks(30);
        check(!stand_by, "releasing K2 cannot continue the previous parking run");

        press_start();
        start_parking();
        raw_l = raw_l - 50;
        clocks(4);
        check(dut.parking_fault && dut.panel_status == 2 && !stand_by,
              "wrong encoder direction locks stop and preserves the fault");
        clocks(20);
        check(dut.parking_fault && !stand_by, "fault remains visible after the motor outputs are disabled");
        $finish;
    end

    initial begin
        #300_000;
        $fatal(1, "parking handoff test timed out");
    end
endmodule
