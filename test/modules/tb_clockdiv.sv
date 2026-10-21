`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_clockdiv.fst"
`endif

module tb_clockdiv;
    reg clk;
    reg rst;
    reg [15:0] div_int;
    reg [7:0] div_frac;

    wire tick;

    clockdiv dut (
        .clk(clk),
        .rst(rst),
        .div_int(div_int),
        .div_frac(div_frac),
        .tick(tick)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_clockdiv);
    end

`ifdef SV_TEST
    initial clk = 0;
    always #5 clk = ~clk;

    // Restart the divider with a new divisor. The first tick comes on the
    // first cycle after rst falls.
    task automatic restart(input [15:0] i, input [7:0] f);
        @(negedge clk);
        rst = 1;
        div_int = i;
        div_frac = f;
        @(negedge clk);
        rst = 0;
        #1;
        if (tick !== 1'b1)
            $fatal(1, "No tick on the first cycle after restart (div %0d.%0d)", i, f);
    endtask

    // Count the cycles from the current tick to the next one.
    task automatic next_period(output int cycles);
        cycles = 0;
        do begin
            @(negedge clk);
            #1;
            cycles++;
        end while (tick !== 1'b1);
    endtask

    // Every period must be floor(d) or floor(d) + 1, and the sum of the first
    // 'periods' periods must match the delta-sigma sum exactly.
    task automatic check_divisor(input [15:0] i, input [7:0] f, input int periods);
        int len, total, acc, expected, base;
        base = (i == 0) ? 65536 : i;
        restart(i, f);
        total = 0;
        expected = 0;
        acc = 0;
        for (int p = 0; p < periods; p++) begin
            next_period(len);
            acc += f;
            expected += base + ((acc >= 256) ? 1 : 0);
            acc %= 256;
            if (len != base && len != base + 1)
                $fatal(1, "div %0d.%0d: period %0d was %0d cycles", i, f, p, len);
            total += len;
            if (total != expected)
                $fatal(1, "div %0d.%0d: %0d periods took %0d cycles, expected %0d",
                       i, f, p + 1, total, expected);
        end
    endtask

    int len;

    initial begin
        rst = 1;
        div_int = 1;
        div_frac = 0;
        repeat (2) @(posedge clk);

        // Divisor 1: tick on every cycle.
        restart(1, 0);
        for (int i = 0; i < 20; i++) begin
            @(negedge clk);
            #1;
            if (tick !== 1'b1)
                $fatal(1, "Divisor 1 missed a tick at cycle %0d", i);
        end

        // Integer divisors give exact periods.
        check_divisor(2, 0, 20);
        check_divisor(3, 0, 20);
        check_divisor(7, 0, 20);

        // Divisor 2.5 alternates 2 and 3 cycles (datasheet figure 47).
        restart(2, 8'h80);
        for (int i = 0; i < 10; i++) begin
            next_period(len);
            if (len != ((i % 2 == 0) ? 2 : 3))
                $fatal(1, "Divisor 2.5 period %0d was %0d cycles", i, len);
        end

        // Other fractions keep the long-run average exact.
        check_divisor(1, 8'h40, 64);    // 1.25
        check_divisor(4, 8'hC0, 64);    // 4.75
        check_divisor(10, 8'h01, 300);  // 10 + 1/256

        // div_int = 0 means 65536.
        check_divisor(0, 0, 2);

        // Restart mid-period resets the phase.
        restart(5, 0);
        repeat (2) @(negedge clk);
        restart(5, 0);
        next_period(len);
        if (len != 5)
            $fatal(1, "Period after restart was %0d cycles", len);

        // A divisor change mid-period takes effect from the next period.
        restart(3, 0);
        @(negedge clk);
        div_int = 6;        // 2 cycles of the current 3-cycle period remain
        next_period(len);
        if (len != 2)
            $fatal(1, "Current period changed length after a divisor change: %0d", len);
        next_period(len);
        if (len != 6)
            $fatal(1, "Period after divisor change was %0d cycles", len);

        $display("CLOCKDIV SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
