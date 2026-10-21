`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_isr.fst"
`endif

module tb_isr;
    reg clk;
    reg rst;
    reg ce;
    reg load;
    reg [5:0] load_cnt;
    reg shift;
    reg [4:0] n;
    reg dir;
    reg [31:0] din;

    wire [31:0] q;
    wire [5:0] cnt;
    wire [31:0] shift_q;
    wire [5:0] shift_cnt;

    isr dut (
        .clk(clk),
        .rst(rst),
        .ce(ce),
        .load(load),
        .load_cnt(load_cnt),
        .shift(shift),
        .n(n),
        .dir(dir),
        .din(din),
        .q(q),
        .cnt(cnt),
        .shift_q(shift_q),
        .shift_cnt(shift_cnt)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_isr);
    end

`ifdef SV_TEST
    // Reference model, written bit by bit so it shares no code with the RTL.
    function automatic [31:0] model_shift(input [31:0] old_q, input [31:0] src,
                                          input [4:0] bits, input right);
        int m;
        reg [31:0] r;
        begin
            m = (bits == 0) ? 32 : bits;
            for (int b = 0; b < 32; b++) begin
                if (right)  // old bits move down, src[m-1:0] fills the top
                    r[b] = (b < 32 - m) ? old_q[b + m] : src[b - (32 - m)];
                else        // old bits move up, src[m-1:0] fills the bottom
                    r[b] = (b >= m) ? old_q[b - m] : src[b];
            end
            model_shift = r;
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
    reg [5:0] exp_cnt;

    task automatic idle_inputs();
        load = 0;
        shift = 0;
        load_cnt = 0;
        n = 0;
        dir = 0;
        din = 0;
    endtask

    // Drive on the falling edge, then check just after the rising edge.
    task automatic do_load(input [31:0] value, input [5:0] count);
        @(negedge clk);
        idle_inputs();
        load = 1;
        din = value;
        load_cnt = count;
        exp_q = value;
        exp_cnt = (count > 32) ? 32 : count;
        @(posedge clk);
        #1;
        if (q !== exp_q || cnt !== exp_cnt)
            $fatal(1, "Load %h/%0d gave q=%h cnt=%0d", value, count, q, cnt);
    endtask

    task automatic do_shift(input [31:0] src, input [4:0] bits, input right);
        @(negedge clk);
        idle_inputs();
        shift = 1;
        din = src;
        n = bits;
        dir = right;
        exp_q = model_shift(q, src, bits, right);
        exp_cnt = model_cnt(cnt, bits);
        #1;
        // shift_q / shift_cnt must predict the next register values.
        if (shift_q !== exp_q || shift_cnt !== exp_cnt)
            $fatal(1, "Look-ahead wrong for src=%h n=%0d dir=%0d: shift_q=%h shift_cnt=%0d, expected %h/%0d",
                   src, bits, right, shift_q, shift_cnt, exp_q, exp_cnt);
        @(posedge clk);
        #1;
        if (q !== exp_q || cnt !== exp_cnt)
            $fatal(1, "Shift src=%h n=%0d dir=%0d gave q=%h cnt=%0d, expected %h/%0d",
                   src, bits, right, q, cnt, exp_q, exp_cnt);
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
        if (q !== 0 || cnt !== 0)
            $fatal(1, "Reset did not clear the ISR: q=%h cnt=%0d", q, cnt);

        // Left shift: new bits enter at the bottom (example from the spec).
        do_load(32'h0000_00A5, 0);
        do_shift(32'h0000_000B, 4, 0);
        if (q !== 32'h0000_0A5B)
            $fatal(1, "Left shift example gave %h", q);

        // Right shift: new bits enter at the top.
        do_load(32'hA500_0000, 0);
        do_shift(32'h0000_000B, 4, 1);
        if (q !== 32'hBA50_0000)
            $fatal(1, "Right shift example gave %h", q);

        // n = 0 means a full 32-bit shift in either direction.
        do_shift(32'h0123_4567, 0, 1);
        if (q !== 32'h0123_4567 || cnt !== 32)
            $fatal(1, "32-bit right shift gave q=%h cnt=%0d", q, cnt);
        do_shift(32'h89AB_CDEF, 0, 0);
        if (q !== 32'h89AB_CDEF)
            $fatal(1, "32-bit left shift gave q=%h", q);

        // Source bits above n must be ignored.
        do_load(0, 0);
        do_shift(32'hFFFF_FFF5, 3, 0);
        if (q !== 32'h0000_0005)
            $fatal(1, "Source bits above n leaked into q=%h", q);

        // UART-style receive: eight 1-bit right shifts put the byte in [31:24].
        do_load(0, 0);
        for (int i = 0; i < 8; i++)
            do_shift((32'h5A >> i) & 1, 1, 1);
        if (q !== 32'h5A00_0000 || cnt !== 8)
            $fatal(1, "LSB-first byte receive gave q=%h cnt=%0d", q, cnt);

        // The count saturates at 32, and load_cnt clamps to 32.
        do_load(0, 30);
        do_shift(1, 5, 0);
        if (cnt !== 32)
            $fatal(1, "Count did not saturate: %0d", cnt);
        do_load(0, 40);

        // Load wins over shift in the same cycle (autopush clears the ISR).
        do_load(32'h0000_00FF, 8);
        @(negedge clk);
        idle_inputs();
        load = 1;
        shift = 1;
        n = 8;
        din = 0;
        @(posedge clk);
        #1;
        if (q !== 0 || cnt !== 0)
            $fatal(1, "Load did not take priority over shift: q=%h cnt=%0d", q, cnt);

        // With ce low, neither load nor shift may change the register.
        do_load(32'h1111_1111, 4);
        @(negedge clk);
        ce = 0;
        idle_inputs();
        shift = 1;
        din = 32'hF;
        n = 4;
        @(posedge clk);
        @(negedge clk);
        idle_inputs();
        load = 1;
        din = 0;
        @(posedge clk);
        #1;
        if (q !== 32'h1111_1111 || cnt !== 4)
            $fatal(1, "ISR changed while ce was low: q=%h cnt=%0d", q, cnt);
        @(negedge clk);
        ce = 1;
        idle_inputs();

        // With no strobe, the register holds.
        @(posedge clk);
        #1;
        if (q !== 32'h1111_1111 || cnt !== 4)
            $fatal(1, "ISR changed with no strobe: q=%h cnt=%0d", q, cnt);

        // Random loads and shifts checked against the model.
        for (int i = 0; i < 2000; i++) begin
            if (($urandom % 8) == 0)
                do_load($urandom, $urandom % 41);
            else
                do_shift($urandom, $urandom, $urandom);
        end

        // Reset in the middle of a run.
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        #1;
        if (q !== 0 || cnt !== 0)
            $fatal(1, "Mid-run reset did not clear the ISR: q=%h cnt=%0d", q, cnt);

        $display("ISR SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
