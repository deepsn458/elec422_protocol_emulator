`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_osr.fst"
`endif

module tb_osr;
    parameter DATA_WIDTH = 8;
    parameter DW_BITS = $clog2(DATA_WIDTH);

    logic clk;
    logic rst;
    logic ce;
    logic load;
    logic shift;
    logic [DW_BITS-1:0] n;
    logic dir;
    logic [DATA_WIDTH-1:0] din;

    wire [DATA_WIDTH-1:0] q;
    wire [DATA_WIDTH-1:0] shifted;
    wire [DW_BITS:0] cnt;
    wire [DW_BITS:0] shift_cnt;
    int failures = 0;
    osr #(
        .DATA_WIDTH(DATA_WIDTH),
        .DW_BITS(DW_BITS)
    ) dut (
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
    initial clk = 1'b0;
    always #5 clk = ~clk;

    task finish_test();
        @(posedge clk);
        #0.01;
        $finish;
    endtask

    initial begin
        // Add test task calls here.
        load_input();
        shift_left();
        load_input();
        shift_right();
        report_results();
        finish_test();
    end

    task load_input();
        @(negedge clk);
        rst = 1;
        @(posedge clk);
        @(negedge clk);
        rst = 0;
        din = 8'hA5;
        load = 1;
        ce = 1;
        @(posedge clk);
        #0.01;
        if (q != 8'hA5 || cnt != 0) begin
            $fatal(1,"inital load failed, abort test: %h", q);
        end
    endtask

        task shift_left();
            @(negedge clk);
            n = 4;
            load = 0;
            shift  = 1;
            dir = 0;
          #0.01;
            if (shifted != 8'h0A) begin  //shifted output appears combinationally
                failures++;
                $error("shifted output incorrect %h", shifted);
            end

            @(posedge clk);
            #0.01;
            if (q != 8'h50 || cnt != 4) begin
                failures++;
                $error ("osr contents not preserved %h, cnt %d", q, cnt);
            end
        endtask
       
        task shift_right();
            @(negedge clk);
            n = 4;
            shift = 1;
            load = 0;
            dir = 1;
            #0.01;
            if (shifted != 8'h05) begin  //shifted output appears combinationally
                failures++;
                $error("shifted output incorrect %h. Rest: %h", shifted, dut.rest);
            end

            @(posedge clk);
            #0.01;
            if (q != 8'h0A || cnt != 4) begin
                failures++;
                $error ("osr contents not preserved %h, cnt %d", q, cnt);
            end
        endtask

        task report_results();
            if (failures == 0)
                $display("OSR shift tests passed");
            else
                $display("OSR shift tests: %0d case(s) failed", failures);
            $finish;
        endtask


`endif
endmodule
