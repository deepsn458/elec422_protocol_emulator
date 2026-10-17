`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_fifo.fst"
`endif

module tb_fifo;
    parameter DATA_WIDTH = 32;
    parameter DEPTH = 4;
    parameter DEPTH_BITS = $clog2(DEPTH);

    reg clk;
    reg rst;
    reg [DATA_WIDTH-1:0] d_in;
    reg w_en;
    reg r_en;

    wire [DATA_WIDTH-1:0] d_out;
    wire [DEPTH_BITS:0] wptr;
    wire [DEPTH_BITS:0] rptr;

    fifo #(.DATA_WIDTH(DATA_WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk),
        .rst(rst),
        .d_in(d_in),
        .w_en(w_en),
        .r_en(r_en),
        .d_out(d_out),
        .wptr(wptr),
        .rptr(rptr)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_fifo);
    end

`ifdef SV_TEST
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        rst = 1;
        d_in = 0;
        w_en = 0;
        r_en = 0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;
        if (wptr !== 0 || rptr !== 0)
            $fatal(1, "Reset did not clear FIFO pointers");

        // Reading an empty FIFO must leave the read pointer unchanged.
        r_en = 1;
        @(posedge clk);
        #1;
        if (rptr !== 0)
            $fatal(1, "Empty read advanced rptr to %0d", rptr);

        @(negedge clk);
        r_en = 0;
        w_en = 1;
        d_in = 32'h12345678;
        @(posedge clk);
        #1;
        if (wptr !== 1)
            $fatal(1, "Write did not advance wptr to 1: %0d", wptr);

        // Changing data without w_en must leave the write pointer unchanged.
        @(negedge clk);
        w_en = 0;
        d_in = 32'h87654321;
        @(posedge clk);
        #1;
        if (wptr !== 1)
            $fatal(1, "Disabled write advanced wptr to %0d", wptr);

        @(negedge clk);
        r_en = 1;
        @(posedge clk);
        #1;
        if (d_out !== 32'h12345678 || rptr !== 1)
            $fatal(1, "Readback failed: d_out=%h rptr=%0d", d_out, rptr);

        // Reset the pointers before checking a full FIFO.
        @(negedge clk);
        r_en = 0;
        rst = 1;
        @(posedge clk);
        #1;
        @(negedge clk);
        rst = 0;

        // Fill every slot, then verify a write while full is blocked.
        for (int i = 0; i < DEPTH; i++) begin
            @(negedge clk);
            w_en = 1;
            d_in = i;
            @(posedge clk);
            #1;
        end
        if (wptr !== DEPTH || dut.full !== 1'b1)
            $fatal(1, "FIFO did not become full: wptr=%0d", wptr);

        @(negedge clk);
        d_in = 32'hdeadbeef;
        @(posedge clk);
        #1;
        if (wptr !== DEPTH)
            $fatal(1, "Full write advanced wptr to %0d", wptr);

        $display("FIFO SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
