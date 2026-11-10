`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_isr_fifo_spi.fst"
`endif

// Data path: isr -> RX FIFO -> spi_slave -> spi_master.
//
// Each pass shifts FIFO_DEPTH 16-bit words into the ISR 4 bits at a time
// (like four `in pins, 4`), pushes each full ISR into the RX FIFO, and then
// pops the FIFO one word per SPI frame onto spi_slave's tx_data. spi_master
// reads the words back over SPI, and they must match, in order, the words
// loaded into the ISR. Passes cover every CPOL / CPHA mode with both ISR
// shift directions.
module tb_isr_fifo_spi;
    parameter DATA_WIDTH = 16;
    parameter DW_BITS    = $clog2(DATA_WIDTH);
    parameter FIFO_DEPTH = 4;
    parameter DEPTH_BITS = $clog2(FIFO_DEPTH);
    parameter CLK_DIV    = 4;
    parameter NIBBLES    = DATA_WIDTH / 4;

    logic clk;
    logic rst;

    // ISR controls (what sm drives for IN / PUSH)
    logic                  isr_clear;
    logic                  isr_shift;
    logic                  isr_dir;
    logic [DATA_WIDTH-1:0] isr_din;
    wire  [DATA_WIDTH-1:0] isr_q;
    wire  [DW_BITS:0]      isr_cnt;
    wire  [DATA_WIDTH-1:0] isr_shift_q;
    wire  [DW_BITS:0]      isr_shift_cnt;

    // RX FIFO controls
    logic                  rx_push;
    logic                  rx_pop;
    wire  [DATA_WIDTH-1:0] fifo_out;
    wire  [DEPTH_BITS:0]   wptr;
    wire  [DEPTH_BITS:0]   rptr;

    // SPI
    logic                  cpol;
    logic                  cpha;
    logic                  start;
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

    int failures = 0;

    isr #(
        .DATA_WIDTH(DATA_WIDTH),
        .DW_BITS(DW_BITS)
    ) u_isr (
        .clk(clk),
        .rst(rst | isr_clear),             // PUSH clears the ISR through rst, as in sm
        .ce(1'b1),
        .load(1'b0),
        .load_cnt('0),
        .shift(isr_shift),
        .n(DW_BITS'(4)),                   // 4 bits per IN
        .dir(isr_dir),
        .din(isr_din),
        .q(isr_q),
        .cnt(isr_cnt),
        .shift_q(isr_shift_q),
        .shift_cnt(isr_shift_cnt)
    );

    fifo #(
        .DEPTH(FIFO_DEPTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_rx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(isr_q),
        .w_en(rx_push),
        .r_en(rx_pop),
        .d_out(fifo_out),
        .wptr(wptr),
        .rptr(rptr)
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
        .tx_data(fifo_out),
        .rx_data(s_rx_data),
        .rx_valid(s_rx_valid)
    );

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
        .tx_data('0),                      // master only reads in this test
        .busy(busy),
        .rx_data(m_rx_data),
        .rx_valid(m_rx_valid)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_isr_fifo_spi);
    end

`ifdef SV_TEST
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Words the master received, in arrival order.
    logic [DATA_WIDTH-1:0] received [$];
    always @(posedge clk) if (m_rx_valid) received.push_back(m_rx_data);

    initial begin
        setup_test();
        for (int m = 0; m < 4; m++) begin
            pass_test(m[1], m[0], 1'b0);
            pass_test(m[1], m[0], 1'b1);
        end
        report_results();
    end

    // Shift one word into the ISR as NIBBLES 4-bit INs. Shifting left, the
    // most significant nibble goes first; shifting right, the least
    // significant nibble goes first. Either way q ends up equal to word.
    task automatic load_isr_word(input logic [DATA_WIDTH-1:0] word,
                                 input string name);
        for (int i = 0; i < NIBBLES; i++) begin
            int idx = isr_dir ? i : NIBBLES - 1 - i;
            @(negedge clk);
            isr_din   = DATA_WIDTH'(word[4*idx +: 4]);
            isr_shift = 1;
        end
        @(negedge clk);
        isr_shift = 0;
        $display("%s: loaded    %h into ISR (q=%h)", name, word, isr_q);
        if (isr_q !== word || isr_cnt !== DATA_WIDTH) begin
            failures++;
            $error("%s: ISR q=%h cnt=%0d after loading %h", name, isr_q, isr_cnt, word);
        end
    endtask

    // PUSH: write the ISR into the RX FIFO and clear the ISR in one cycle.
    task automatic push_isr(input string name);
        rx_push   = 1;
        isr_clear = 1;
        @(negedge clk);
        rx_push   = 0;
        isr_clear = 0;
        if (isr_q !== '0 || isr_cnt !== '0) begin
            failures++;
            $error("%s: ISR not cleared by push (q=%h cnt=%0d)", name, isr_q, isr_cnt);
        end
    endtask

    // Pop one word onto spi_slave's tx_data, then run one SPI frame.
    task automatic pop_and_send();
        @(negedge clk);
        rx_pop = 1;
        @(negedge clk);
        rx_pop = 0;
        // The slave picks up tx_data while cs_n is high, so the popped word
        // is in place before the master starts the frame.
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
    endtask

    task automatic pass_test(input logic pol, input logic pha, input logic dir);
        logic [DATA_WIDTH-1:0] words [FIFO_DEPTH];
        string name;
        $sformat(name, "cpol=%0d cpha=%0d isr_dir=%0d", pol, pha, dir);

        words[0] = 16'hA5C3;
        for (int k = 1; k < FIFO_DEPTH; k++) words[k] = $urandom;

        @(negedge clk);
        cpol    = pol;
        cpha    = pha;
        isr_dir = dir;
        received.delete();
        repeat (4 * CLK_DIV) @(negedge clk);

        // ISR -> RX FIFO, FIFO_DEPTH times.
        foreach (words[k]) begin
            load_isr_word(words[k], name);
            push_isr(name);
        end
        // The pointers wrap, so take the level at pointer width.
        if ((DEPTH_BITS+1)'(wptr - rptr) !== FIFO_DEPTH || u_rx_fifo.full !== 1'b1) begin
            failures++;
            $error("%s: RX FIFO not full after %0d pushes (wptr=%0d rptr=%0d)",
                   name, FIFO_DEPTH, wptr, rptr);
        end

        // RX FIFO -> spi_slave -> spi_master, one word per frame.
        repeat (FIFO_DEPTH) pop_and_send();
        @(negedge clk);
        if (u_rx_fifo.empty !== 1'b1) begin
            failures++;
            $error("%s: RX FIFO not empty after %0d pops", name, FIFO_DEPTH);
        end

        // Decode what the master received and compare with what was loaded.
        if (received.size() != FIFO_DEPTH) begin
            failures++;
            $error("%s: master received %0d words, expected %0d",
                   name, received.size(), FIFO_DEPTH);
        end
        foreach (received[k])
            $display("%s: recovered %h (word %0d)", name, received[k], k);
        foreach (words[k]) begin
            if (k < received.size() && received[k] !== words[k]) begin
                failures++;
                $error("%s: word %0d received %h, loaded %h", name, k, received[k], words[k]);
            end
        end
    endtask

    task setup_test();
        rst       = 1;
        isr_clear = 0;
        isr_shift = 0;
        isr_dir   = 0;
        isr_din   = '0;
        rx_push   = 0;
        rx_pop    = 0;
        cpol      = 0;
        cpha      = 0;
        start     = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    task report_results();
        if (failures == 0)
            $display("ISR -> FIFO -> SPI tests passed");
        else
            $display("ISR -> FIFO -> SPI tests: %0d case(s) failed", failures);
        $finish;
    endtask

`endif
endmodule
