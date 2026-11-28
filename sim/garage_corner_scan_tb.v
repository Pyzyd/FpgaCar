`timescale 1ns/1ns

module garage_corner_scan_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0, frame_valid = 0;
    wire [15:0] addr;
    wire release_frame, done, corner, pair_valid;
    wire [9:0] center;
    reg [7:0] frame [0:57599];
    reg [7:0] gray;
    always @(posedge clk) gray <= frame[addr];
    garage_corner_scan dut (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid), .read_y(gray),
        .read_addr(addr), .frame_release(release_frame), .frame_done(done),
        .corner_seen(corner), .pair_valid(pair_valid), .center_x_sum(center)
    );

    task scan;
        begin
            frame_valid = 1;
            wait (done);
            @(negedge clk); frame_valid = 0;
            @(negedge clk);
        end
    endtask

    integer x, y, j, k, list_file, next_file;
    reg [8*256-1:0] list_path, image_path;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        if ($value$plusargs("images=%s", list_path)) begin
            list_file = $fopen(list_path, "r");
            if (list_file == 0) $fatal(1, "could not open image list");
            next_file = $fscanf(list_file, "%s", image_path);
            while (next_file == 1) begin
                $readmemh(image_path, frame);
                scan();
                $display("PHOTO %0s corner=%0d pair=%0d mx=%0d max=%0d L=%0d,%0d,%0d R=%0d,%0d,%0d",
                         image_path, corner, pair_valid, 2*center+2, dut.best_any,
                         dut.left_x, dut.left_y, dut.best_left, dut.right_x, dut.right_y, dut.best_right);
                next_file = $fscanf(list_file, "%s", image_path);
            end
            $fclose(list_file);
        end else begin
            for (k = 0; k < 57600; k = k + 1) frame[k] = 100;
            scan();
            if (corner || pair_valid) $fatal(1, "flat background detected");
            for (x = 24; x <= 294; x = x + 1) begin
                y = 99 + (x-24)/32;
                for (j = -1; j <= 1; j = j + 1) frame[(y+j)*320+x] = 25;
            end
            for (j = 0; j <= 20; j = j + 1)
                for (k = -3; k <= 3; k = k + 1) frame[(107+j)*320+294+j+k] = 25;
            scan();
            if (!corner || pair_valid) $fatal(1, "right corner alone should only slow");
            for (j = 0; j <= 20; j = j + 1)
                for (k = -3; k <= 3; k = k + 1) frame[(99+j)*320+24-j+k] = 25;
            scan();
            if (!corner || !pair_valid || center < 307 || center > 331)
                $fatal(1, "two connected corners should be centered (xsum=%0d)", center);
            for (x = 130; x <= 252; x = x + 1)
                for (y = 92; y <= 113; y = y + 1) frame[y*320+x] = 100;
            scan();
            if (pair_valid) $fatal(1, "two unconnected corners cannot form a parking pair");

            // A slightly smaller U and a negative slope, as seen with a different camera pose.
            for (k = 0; k < 57600; k = k + 1) frame[k] = 100;
            for (x = 52; x <= 266; x = x + 1) begin
                y = 91 - (x-52)/12;
                for (j = -1; j <= 1; j = j + 1) frame[(y+j)*320+x] = 25;
            end
            for (j = 0; j <= 20; j = j + 1)
                for (k = -3; k <= 3; k = k + 1) begin
                    frame[(91+j)*320+52-j+k] = 25;
                    frame[(74+j)*320+266+j+k] = 25;
                end
            scan();
            if (!corner || !pair_valid || center < 307 || center > 331)
                $fatal(1, "narrower tilted U should pass (xsum=%0d)", center);
            $display("PASS: flat background, single corner, connected pair, disconnected tape and narrower tilted U");
        end
        $finish;
    end
    initial begin
        #900_000_000;
        $fatal(1, "scan did not finish");
    end
endmodule
