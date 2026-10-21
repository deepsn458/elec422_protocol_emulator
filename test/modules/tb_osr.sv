`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_osr.fst"
`endif

module tb_osr;
    reg clk;
    reg rst;
    reg ce;
    reg load;
    reg shift;
    reg [4:0] n;
    reg dir;
    reg [31:0] din;

    wire [31:0] q;
    wire [31:0] shifted;
    wire [5:0] cnt;
    wire [5:0] shift_cnt;

    osr dut (
        .clk(clk),
        .rst(rst),
        .ce(ce),
        .load(load),
        .shift(shift),
        .n(n),
        .dir(dir),
        .din(din),
        .q(q),
        .shifted(shifted),
        .cnt(cnt),
        .shift_cnt(shift_cnt)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_osr);
    end

`ifdef SV_TEST
    // Reference model, written bit by bit so it shares no code with the RTL.

    // Bits leaving on an OUT, right-aligned.
    function automatic [31:0] model_out(input [31:0] old_q, input [4:0] bits, input right);
        int m;
        reg [31:0] r;
        begin
            m = (bits == 0) ? 32 : bits;
            r = 0;
            for (int b = 0; b < m; b++)
                r[b] = right ? old_q[b] : old_q[32 - m + b];
            model_out = r;
        end
    endfunction

    // Bits left in the register after an OUT, zero filled.
    function automatic [31:0] model_rest(input [31:0] old_q, input [4:0] bits, input right);
        int m;
        reg [31:0] r;
        begin
            m = (bits == 0) ? 32 : bits;
            for (int b = 0; b < 32; b++) begin
                if (right)
                    r[b] = (b + m < 32) ? old_q[b + m] : 1'b0;
                else
                    r[b] = (b >= m) ? old_q[b - m] : 1'b0;
            end
            model_rest = r;
        end
    endfunction

    function automatic [5:0] model_cnt(input [5:0] old_cnt, input [4:0] bits);
        int sum;
        begin
            sum = old_cnt + ((bits == 0) ? 32 : bits);
            model_cnt = (sum > 32) ? 32 : sum;
        end
    endfunction

    reg [31:0] exp_q;
    reg [31:0] exp_out;
    reg [5:0] exp_cnt;

    task automatic idle_inputs();
        load = 0;
        shift = 0;
        n = 0;
        dir = 0;
        din = 0;
    endtask

    // Drive on the falling edge, then check just after the rising edge.
    task automatic do_load(input [31:0] value);
        @(negedge clk);
        idle_inputs();
        load = 1;
        din = value;
        @(posedge clk);
        #1;
        if (q !== value || cnt !== 0)
            $fatal(1, "Load %h gave q=%h cnt=%0d", value, q, cnt);
    endtask

    task automatic do_shift(input [4:0] bits, input right);
        @(negedge clk);
        idle_inputs();
        shift = 1;
        n = bits;
        dir = right;
        exp_out = model_out(q, bits, right);
        exp_q = model_rest(q, bits, right);
        exp_cnt = model_cnt(cnt, bits);
        #1;
        if (shifted !== exp_out || shift_cnt !== exp_cnt)
            $fatal(1, "OUT n=%0d dir=%0d from q=%h: shifted=%h shift_cnt=%0d, expected %h/%0d",
                   bits, right, q, shifted, shift_cnt, exp_out, exp_cnt);
        @(posedge clk);
        #1;
        if (q !== exp_q || cnt !== exp_cnt)
            $fatal(1, "OUT n=%0d dir=%0d left q=%h cnt=%0d, expected %h/%0d",
                   bits, right, q, cnt, exp_q, exp_cnt);
    endtask

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        rst = 1;
        ce = 1;
        idle_inputs();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;
        // Reset marks the OSR empty so the first OUT with autopull refills it.
        if (q !== 0 || cnt !== 32)
            $fatal(1, "Reset gave q=%h cnt=%0d, expected 0/32", q, cnt);

        // Right shift sends the low bits first (example from the spec).
        do_load(32'h1234_5678);
        do_shift(8, 1);
        if (q !== 32'h0012_3456)
            $fatal(1, "Right shift example left q=%h", q);

        // Left shift sends the high bits first.
        do_load(32'h1234_5678);
        @(negedge clk);
        idle_inputs();
        shift = 1;
        n = 8;
        dir = 0;
        #1;
        if (shifted !== 32'h0000_0012)
            $fatal(1, "Left shift example sent %h", shifted);
        @(posedge clk);
        #1;
        if (q !== 32'h3456_7800 || cnt !== 8)
            $fatal(1, "Left shift example left q=%h cnt=%0d", q, cnt);

        // n = 0 sends all 32 bits and empties the register.
        do_load(32'hCAFE_F00D);
        do_shift(0, 1);
        if (q !== 0 || cnt !== 32)
            $fatal(1, "32-bit OUT left q=%h cnt=%0d", q, cnt);

        // UART-style transmit: 0x5A goes out LSB first, one bit per OUT.
        do_load(32'h0000_005A);
        for (int i = 0; i < 8; i++) begin
            @(negedge clk);
            idle_inputs();
            shift = 1;
            n = 1;
            dir = 1;
            #1;
            if (shifted !== ((32'h5A >> i) & 1))
                $fatal(1, "LSB-first transmit bit %0d was %h", i, shifted);
            @(posedge clk);
            #1;
        end
        if (cnt !== 8)
            $fatal(1, "Count after 8 OUTs was %0d", cnt);

        // The count saturates at 32.
        do_load(32'hFFFF_FFFF);
        do_shift(20, 1);
        do_shift(20, 1);
        if (cnt !== 32)
            $fatal(1, "Count did not saturate: %0d", cnt);

        // Load wins over shift in the same cycle.
        do_load(32'hAAAA_AAAA);
        do_shift(4, 1);
        @(negedge clk);
        idle_inputs();
        load = 1;
        shift = 1;
        n = 4;
        din = 32'h1357_9BDF;
        @(posedge clk);
        #1;
        if (q !== 32'h1357_9BDF || cnt !== 0)
            $fatal(1, "Load did not take priority over shift: q=%h cnt=%0d", q, cnt);

        // With ce low, neither load nor shift may change the register.
        do_load(32'h2222_2222);
        @(negedge clk);
        ce = 0;
        idle_inputs();
        shift = 1;
        n = 4;
        @(posedge clk);
        @(negedge clk);
        idle_inputs();
        load = 1;
        din = 0;
        @(posedge clk);
        #1;
        if (q !== 32'h2222_2222 || cnt !== 0)
            $fatal(1, "OSR changed while ce was low: q=%h cnt=%0d", q, cnt);
        @(negedge clk);
        ce = 1;
        idle_inputs();

        // With no strobe, the register holds.
        @(posedge clk);
        #1;
        if (q !== 32'h2222_2222 || cnt !== 0)
            $fatal(1, "OSR changed with no strobe: q=%h cnt=%0d", q, cnt);

        // Random loads and shifts checked against the model.
        for (int i = 0; i < 2000; i++) begin
            if (($urandom % 8) == 0)
                do_load($urandom);
            else
                do_shift($urandom, $urandom);
        end

        // Reset in the middle of a run.
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        #1;
        if (q !== 0 || cnt !== 32)
            $fatal(1, "Mid-run reset gave q=%h cnt=%0d, expected 0/32", q, cnt);

        $display("OSR SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
