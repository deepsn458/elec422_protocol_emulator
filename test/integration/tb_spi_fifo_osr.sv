`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_spi_fifo_osr.fst"
`endif

// Data path: spi_master -> spi_slave -> TX FIFO -> osr.
//
// Each pass sends FIFO_DEPTH 16-bit words from spi_master. spi_slave's
// rx_valid is tied to the FIFO's w_en, so every received word is written
// straight into the TX FIFO. Then, once per word, the testbench pops the
// FIFO, loads the OSR, and shifts the whole word out with one OUT of n = 0
// (DATA_WIDTH bits) into a check register. The check registers must match,
// in order, the words the master sent. Passes cover every CPOL / CPHA mode
// with both OSR shift directions.
//
// The FIFO's d_out is registered (not first-word fall-through), so each
// word needs a pop cycle before the OSR load can see it.
module tb_spi_fifo_osr;
    parameter DATA_WIDTH = 16;
    parameter DW_BITS    = $clog2(DATA_WIDTH);
    parameter FIFO_DEPTH = 4;
    parameter DEPTH_BITS = $clog2(FIFO_DEPTH);
    parameter CLK_DIV    = 4;

    logic clk;
    logic rst;

    // SPI
    logic                  cpol;
    logic                  cpha;
    logic                  start;
    logic [DATA_WIDTH-1:0] m_tx_data;
    wire                   sclk;
    wire                   cs_n;
    wire                   mosi;
    wire                   miso;
    wire                   miso_oe;
    wire                   busy;
    wire  [DATA_WIDTH-1:0] m_rx_data;
    wire                   m_rx_valid;
    wire  [DATA_WIDTH-1:0] s_rx_data;
    wire                   s_rx_valid;

    // TX FIFO
    logic                  tx_pop;
    wire  [DATA_WIDTH-1:0] fifo_out;
    wire  [DEPTH_BITS:0]   wptr;
    wire  [DEPTH_BITS:0]   rptr;

    // OSR controls (what sm drives for PULL / OUT)
    logic                  osr_load;
    logic                  osr_shift;
    logic [DW_BITS-1:0]    osr_n;
    logic                  osr_dir;
    wire  [DATA_WIDTH-1:0] osr_q;
    wire  [DATA_WIDTH-1:0] osr_shifted;
    wire  [DW_BITS:0]      osr_cnt;
    wire  [DW_BITS:0]      osr_shift_cnt;

    int failures = 0;

    spi_master #(
        .DATA_WIDTH(DATA_WIDTH),
        .CLK_DIV(CLK_DIV)
    ) u_master (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .start(start),
        .tx_data(m_tx_data),
        .busy(busy),
        .rx_data(m_rx_data),
        .rx_valid(m_rx_valid)
    );

    spi_slave #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_slave (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .miso_oe(miso_oe),
        .tx_data('0),                      // slave only receives in this test
        .rx_data(s_rx_data),
        .rx_valid(s_rx_valid)
    );

    fifo #(
        .DEPTH(FIFO_DEPTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_tx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(s_rx_data),
        .w_en(s_rx_valid),                 // every received word is written
        .r_en(tx_pop),
        .d_out(fifo_out),
        .wptr(wptr),
        .rptr(rptr)
    );

    osr #(
        .DATA_WIDTH(DATA_WIDTH),
        .DW_BITS(DW_BITS)
    ) u_osr (
        .clk(clk),
        .rst(rst),
        .ce(1'b1),
        .load(osr_load),
        .shift(osr_shift),
        .n(osr_n),
        .dir(osr_dir),
        .din(fifo_out),
        .q(osr_q),
        .shifted(osr_shifted),
        .cnt(osr_cnt),
        .shift_cnt(osr_shift_cnt)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_spi_fifo_osr);
    end

`ifdef SV_TEST
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        setup_test();
        for (int m = 0; m < 4; m++) begin
            pass_test(m[1], m[0], 1'b0);
            pass_test(m[1], m[0], 1'b1);
        end
        report_results();
    end

    // One SPI frame from the master. Returns once the master drops busy.
    task automatic send_word(input logic [DATA_WIDTH-1:0] word,
                             input string name);
        @(negedge clk);
        m_tx_data = word;
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
        $display("%s: sent      %h", name, word);
    endtask

    // Pop the next word, load it into the OSR, then OUT all DATA_WIDTH bits
    // (n = 0) and capture them in check.
    task automatic pull_and_out(output logic [DATA_WIDTH-1:0] check,
                                input string name);
        // Pop: d_out takes the next word at this clk edge.
        @(negedge clk);
        tx_pop = 1;
        @(negedge clk);
        tx_pop = 0;

        // PULL: load the OSR from the FIFO.
        osr_load = 1;
        @(negedge clk);
        osr_load = 0;
        if (osr_cnt !== '0) begin
            failures++;
            $error("%s: OSR cnt=%0d after load, expected 0 (full)", name, osr_cnt);
        end

        // OUT n = 0: the whole word leaves on shifted this cycle.
        osr_n     = '0;
        osr_shift = 1;
        #1 check = osr_shifted;
        @(negedge clk);
        osr_shift = 0;
        if (osr_q !== '0 || osr_cnt !== DATA_WIDTH) begin
            failures++;
            $error("%s: OSR not empty after OUT (q=%h cnt=%0d)", name, osr_q, osr_cnt);
        end
        $display("%s: recovered %h from OSR", name, check);
    endtask

    task automatic pass_test(input logic pol, input logic pha, input logic dir);
        logic [DATA_WIDTH-1:0] words [FIFO_DEPTH];
        logic [DATA_WIDTH-1:0] check;
        string name;
        $sformat(name, "cpol=%0d cpha=%0d osr_dir=%0d", pol, pha, dir);

        words[0] = 16'hA5C3;
        for (int k = 1; k < FIFO_DEPTH; k++) words[k] = $urandom;

        @(negedge clk);
        cpol    = pol;
        cpha    = pha;
        osr_dir = dir;
        repeat (4 * CLK_DIV) @(negedge clk);

        // spi_master -> spi_slave -> TX FIFO, FIFO_DEPTH times.
        foreach (words[k]) send_word(words[k], name);
        @(negedge clk);
        // The pointers wrap, so take the level at pointer width.
        if ((DEPTH_BITS+1)'(wptr - rptr) !== FIFO_DEPTH || u_tx_fifo.full !== 1'b1) begin
            failures++;
            $error("%s: TX FIFO not full after %0d words (wptr=%0d rptr=%0d)",
                   name, FIFO_DEPTH, wptr, rptr);
        end

        // TX FIFO -> OSR -> check, once per word.
        foreach (words[k]) begin
            pull_and_out(check, name);
            if (check !== words[k]) begin
                failures++;
                $error("%s: word %0d recovered %h, sent %h", name, k, check, words[k]);
            end
        end
        if (u_tx_fifo.empty !== 1'b1) begin
            failures++;
            $error("%s: TX FIFO not empty after %0d pops", name, FIFO_DEPTH);
        end
    endtask

    task setup_test();
        rst       = 1;
        cpol      = 0;
        cpha      = 0;
        start     = 0;
        m_tx_data = '0;
        tx_pop    = 0;
        osr_load  = 0;
        osr_shift = 0;
        osr_n     = '0;
        osr_dir   = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    task report_results();
        if (failures == 0)
            $display("SPI -> FIFO -> OSR tests passed");
        else
            $display("SPI -> FIFO -> OSR tests: %0d case(s) failed", failures);
        $finish;
    endtask

`endif
endmodule
