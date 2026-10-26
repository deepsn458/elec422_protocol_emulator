`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_isr.fst"
`endif

module tb_isr;
    parameter DATA_WIDTH = 8;
    parameter DW_BITS = $clog2(DATA_WIDTH);

    logic clk;
    logic rst;
    logic ce;
    logic load;
    logic [DW_BITS:0] load_cnt;
    logic shift;
    logic [DW_BITS-1:0] n;
    logic dir;
    logic [DATA_WIDTH-1:0] din;

    wire [DATA_WIDTH-1:0] q;
    wire [DW_BITS:0] cnt;
    wire [DATA_WIDTH-1:0] shift_q;
    wire [DW_BITS:0] shift_cnt;
    int failures = 0;

    isr #(
        .DATA_WIDTH(DATA_WIDTH),
        .DW_BITS(DW_BITS)
    ) dut (
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
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        setup_test();
        left_shift_test();
        right_shift_test();
        load_test();
        report_results();
    end

    task left_shift_test();
        // Shift four bits into the LSB end.
        rst = 1;
        @(posedge clk);
        @(negedge clk);
        rst = 0;
        din = 8'h0f;
        ce = 1;
        shift = 1;
        n = 4;
        dir = 0;
        @(posedge clk);
        #0.01;
        if (q !== 8'h0f || cnt !== 4) begin
            failures++;
            $error("left shift failed: q=%h cnt=%0d", q, cnt);
        end

        // Only the low four source bits should be used.
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        @(negedge clk);
        rst = 0;
        din = 8'hff;
        @(posedge clk);
        #0.01;
        if (q !== 8'h0f || cnt !== 4) begin
            failures++;
            $error("left shift source mask failed: q=%h cnt=%0d", q, cnt);
        end

        // A full-width shift overwrites the previous four bits; count saturates.
        @(negedge clk);
        din = 8'haa;
        n = 0;
        @(posedge clk);
        #0.01;
        if (q !== 8'haa || cnt !== DATA_WIDTH) begin
            failures++;
            $error("left shift overflow failed: q=%h cnt=%0d", q, cnt);
        end
    endtask

    task right_shift_test();
        // The low four source bits enter at the MSB end.
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        @(negedge clk);
        rst = 0;
        din = 8'h0f;
        ce = 1;
        shift = 1;
        n = 4;
        dir = 1;
        @(posedge clk);
        #0.01;
        if (q !== 8'hf0 || cnt !== 4) begin
            failures++;
            $error("right shift failed: q=%h cnt=%0d", q, cnt);
        end

        // Source MSBs are ignored when shifting only four bits.
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        @(negedge clk);
        rst = 0;
        din = 8'hff;
        @(posedge clk);
        #0.01;
        if (q !== 8'hf0 || cnt !== 4) begin
            failures++;
            $error("right shift source mask failed: q=%h cnt=%0d", q, cnt);
        end

        // A full-width shift overwrites the previous four bits; count saturates.
        @(negedge clk);
        din = 8'haa;
        n = 0;
        @(posedge clk);
        #0.01;
        if (q !== 8'haa || cnt !== DATA_WIDTH) begin
            failures++;
            $error("right shift overflow failed: q=%h cnt=%0d", q, cnt);
        end

    endtask

    task load_test();
        //the SM should set load_cnt to 0 
        //Load should have priority over shift
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        @(negedge clk);
        rst = 0;
        ce = 1;
        shift = 1;
        din = 4'hf;
        n = 4;
        @(posedge clk);
        @(negedge clk);
        load_cnt = 0;
        load = 1;
        din = 4'hf;
        @(posedge clk);
        #0.01;
        if (q != 4'hf || cnt != 0) begin
            failures++;
            $error("MOV operation failed (either data not transferred or count not reset)", q, cnt);
        end
    endtask

    task setup_test();
        rst = 0;
        ce = 0;
        load = 0;
        load_cnt = '0;
        shift = 0;
        n = '0;
        dir = 0;
        din = '0;
    endtask

    task report_results();
        if (failures == 0)
            $display("ISR shift tests passed");
        else
            $display("ISR shift tests: %0d case(s) failed", failures);
        $finish;
    endtask

   `endif
endmodule
