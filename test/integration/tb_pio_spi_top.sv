`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_pio_spi_top.fst"
`endif
`ifndef HEX_DIR
`define HEX_DIR "integration/assembler_test_outputs/generated"
`endif

// Smoke test for pio_spi_top: spi_master -> spi_slave -> imem / TX FIFO ->
// SM -> RX FIFO / GPIO -> spi_slave -> spi_master.
//
// Programs are the assembler's hex images (40 words: 32 instruction slots +
// 8 config words), sent over SPI exactly as a host would.
//
// For each CPOL / CPHA mode:
//   * rst, then load test_autopull_autopush_loopback over SPI. Checks: no
//     word reaches the TX FIFO during the load, `loaded` rises after word 40,
//     and the SRAM holds the image.
//   * Send N_DATA words. The program copies each TX FIFO word into the RX
//     FIFO (out x, 16 / in x, 16 with autopull + autopush), so each frame
//     returns the previous frame's word on miso, and the first returns 0.
// Then, in mode 0, rst and load test_set_and_wrap: GPIO 4 becomes an output
// and toggles every cycle on the pad.
// No GPIO fault may be raised.
module tb_pio_spi_top;
    parameter DATA_WIDTH    = 16;
    parameter CLK_DIV       = 4;
    parameter IMEM_XFER_CNT = 40;
    parameter N_DATA        = 6;

    logic clk;
    logic rst;

    // SPI
    logic                  cpol, cpha;
    logic                  start;
    logic [DATA_WIDTH-1:0] m_tx_data;
    wire                   sclk, cs_n, mosi, miso, miso_oe;
    wire                   busy;
    wire  [DATA_WIDTH-1:0] m_rx_data;
    wire                   m_rx_valid;

    // Top
    logic                  en;
    wire                   loaded;
    logic [DATA_WIDTH-1:0] ext_in;
    wire  [DATA_WIDTH-1:0] pad_in, pad_out, pad_oe;
    wire                   fault;
    wire  [2:0]            fault_cause;
    wire  [7:0]            irq_flags;

    spi_master #(.DATA_WIDTH(DATA_WIDTH), .CLK_DIV(CLK_DIV)) u_master (
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

    pio_spi_top #(.DATA_WIDTH(DATA_WIDTH), .IMEM_XFER_CNT(IMEM_XFER_CNT)) dut (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .miso_oe(miso_oe),
        .en(en),
        .restart(1'b0),
        .clkdiv_restart(1'b0),
        .loaded(loaded),
        .pad_in(pad_in),
        .pad_out(pad_out),
        .pad_oe(pad_oe),
        .clr_fault(1'b0),
        .fault(fault),
        .fault_cause(fault_cause),
        .irq_flags(irq_flags)
    );

    // Pads loop back: a driven pad reads its own level.
    assign pad_in = (pad_oe & pad_out) | (~pad_oe & ext_in);

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_pio_spi_top);
    end

`ifdef SV_TEST
    initial clk = 1'b0;
    always #5 clk = ~clk;

    int failures = 0;

    initial begin
        #20ms;
        $error("timeout");
        $finish;
    end

    task automatic check(input logic ok, input string msg);
        if (ok !== 1'b1) begin
            failures++;
            $error("%s", msg);
        end
    endtask

    // A word written to the TX FIFO before `loaded` is a steering error.
    always @(posedge clk)
        if (!rst && dut.tx_we && !loaded)
            check(0, "TX FIFO written during the load");

    always @(posedge clk)
        if (!rst && fault)
            check(0, $sformatf("GPIO fault raised (cause %b)", fault_cause));

    // One SPI frame. Returns the word the master read on miso.
    task automatic xfer(input logic [DATA_WIDTH-1:0] word,
                        output logic [DATA_WIDTH-1:0] got);
        @(negedge clk);
        m_tx_data = word;
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
        got = m_rx_data;
    endtask

    task automatic reset_dut(input logic pol, input logic pha);
        @(negedge clk);
        rst   = 1;
        cpol  = pol;
        cpha  = pha;
        start = 0;
        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);
    endtask

    task automatic load_program(input string name);
        logic [DATA_WIDTH-1:0] img [IMEM_XFER_CNT];
        logic [DATA_WIDTH-1:0] got;
        $readmemh({`HEX_DIR, "/", name, ".hex"}, img);
        for (int i = 0; i < IMEM_XFER_CNT; i++) begin
            check(loaded === 1'b0, $sformatf("%s: loaded high before word %0d", name, i));
            xfer(img[i], got);
        end
        repeat (4) @(negedge clk);
        check(loaded === 1'b1, $sformatf("%s: loaded low after %0d words", name, IMEM_XFER_CNT));
        for (int i = 0; i < IMEM_XFER_CNT; i++)
            check(dut.u_imem.i_SRAM_1P_behavioral.memory[i] === img[i],
                  $sformatf("%s: imem[%0d]=%h, sent %h", name, i,
                            dut.u_imem.i_SRAM_1P_behavioral.memory[i], img[i]));
        check(dut.tx_count == 0, $sformatf("%s: TX FIFO not empty after load", name));
    endtask

    task automatic test_loopback(input logic pol, input logic pha);
        logic [DATA_WIDTH-1:0] sent [N_DATA];
        logic [DATA_WIDTH-1:0] got;
        string tag = $sformatf("loopback cpol=%0d cpha=%0d", pol, pha);
        reset_dut(pol, pha);
        load_program("test_autopull_autopush_loopback");
        for (int i = 0; i < N_DATA; i++) begin
            sent[i] = DATA_WIDTH'($urandom);
            xfer(sent[i], got);
            check(got === (i == 0 ? '0 : sent[i-1]),
                  $sformatf("%s: frame %0d returned %h, expected %h", tag, i, got,
                            i == 0 ? '0 : sent[i-1]));
        end
        xfer('0, got);
        check(got === sent[N_DATA-1],
              $sformatf("%s: last frame returned %h, expected %h", tag, got, sent[N_DATA-1]));
        // The flush frame's 0 is looped back too.
        repeat (20) @(negedge clk);
        check(dut.rx_count == 1 && dut.rx_head === '0,
              $sformatf("%s: RX FIFO holds %0d words, expected only the flush word", tag, dut.rx_count));
        $display("%s: done", tag);
    endtask

    task automatic test_gpio_squarewave();
        reset_dut(1'b0, 1'b0);
        load_program("test_set_and_wrap");
        repeat (20) @(negedge clk);       // boot + set pindirs
        check(pad_oe[4] === 1'b1, "set_and_wrap: GPIO 4 not driven");
        for (int i = 0; i < 10; i++) begin
            logic prev = pad_in[4];
            @(negedge clk);
            check(pad_in[4] === ~prev, $sformatf("set_and_wrap: GPIO 4 did not toggle (cycle %0d)", i));
        end
        // Output-only pads (12-15) are always driven; of the rest only GPIO 4.
        check(pad_oe === 16'hF010, $sformatf("set_and_wrap: pad_oe=%h, expected f010", pad_oe));
        $display("set_and_wrap: done");
    endtask

    initial begin
        rst = 1; en = 1; ext_in = '0; start = 0; m_tx_data = '0; cpol = 0; cpha = 0;
        for (int m = 0; m < 4; m++)
            test_loopback(m[1], m[0]);
        test_gpio_squarewave();
        if (failures == 0) $display("PASS: tb_pio_spi_top");
        else               $display("FAIL: tb_pio_spi_top, %0d failure(s)", failures);
        $finish;
    end
`endif
endmodule
