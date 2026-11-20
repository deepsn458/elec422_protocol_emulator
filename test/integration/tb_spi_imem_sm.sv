`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_spi_imem_sm.fst"
`endif

// Program load path: spi_master -> spi_slave -> instruction SRAM, then
// spi_slave -> TX FIFO.
//
// The instruction memory is the IHP 64x16 SRAM behavioral model
// (test/ihp_sram, compiled with FUNCTIONAL), not a testbench mock.
//
// spi_slave counts received words and latches `loaded` after
// IMEM_XFER_CNT (40) of them: 32 instruction slots + 8 config words. The
// glue below (what project.v will hold) steers each word on rx_valid:
//   * !loaded: write the SRAM at load_addr (0..39), the FIFO gets nothing.
//   *  loaded: push into the TX FIFO, and the SRAM address / read enable
//              come from the SM.
// The SM is held in reset until one cycle after `loaded` (its loaded_q), so
// on the edge `loaded` rises the SM still has PC = 32 and mem_addr = 32, and
// on the next edge the SRAM reads address 32 and the SM leaves reset with
// the first config word on instr.
//
// Sequence: 40 words over SPI, one bogus word that must land in the FIFO.
// Checks:
//   * no word reaches the FIFO during the load
//   * the edge `loaded` rises: PC = 32, SM in reset, SRAM addressed by the SM
//     at 32, and the 40th word already written
//   * the next edge: instr = mem[32] and the SM is out of reset
//   * the SRAM holds all 40 words; boot copies words 32-39 into the config
//     registers
//   * the bogus word is in the FIFO and the SRAM is unchanged
//
// Waveforms are recorded only from the 36th word on (after 35 words sent).
module tb_spi_imem_sm;
    parameter DATA_WIDTH    = 16;
    parameter FIFO_DEPTH    = 4;
    parameter DEPTH_BITS    = $clog2(FIFO_DEPTH);
    parameter CLK_DIV       = 4;
    parameter IMEM_XFER_CNT = 40;
    parameter DUMP_AFTER    = 35;            // words sent before dumping starts
    localparam logic [5:0] CFG_BASE = 6'd32;
    localparam logic [DATA_WIDTH-1:0] BOGUS = 16'hBAD0;

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
    wire                   s_loaded;

    // Instruction SRAM
    wire  [5:0]            sram_addr;
    wire                   sram_wen;
    wire                   sram_ren;
    wire  [15:0]           sram_dout;
    logic [5:0]            load_addr;

    // TX FIFO
    wire                   fifo_we;
    wire  [DATA_WIDTH-1:0] fifo_out;
    wire  [DEPTH_BITS:0]   wptr;
    wire  [DEPTH_BITS:0]   rptr;
    wire  [DEPTH_BITS:0]   fifo_level;

    // SM
    wire  [5:0]            sm_mem_addr;
    wire                   sm_read_en;
    wire                   sm_tx_pop;
    wire  [DATA_WIDTH-1:0] sm_rx_data;
    wire                   sm_rx_push;
    wire  [DATA_WIDTH-1:0] pins_re, pins_we, pins_wdata, dirs_we, dirs_wdata;
    wire  [7:0]            irq_set, irq_clr;

    logic [DATA_WIDTH-1:0] words [IMEM_XFER_CNT];
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
        .DATA_WIDTH(DATA_WIDTH),
        .IMEM_XFER_CNT(IMEM_XFER_CNT)
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
        .rx_valid(s_rx_valid),
        .loaded(s_loaded)
    );

    // ---- Load / run steering (to move into project.v) ----------------------
    assign sram_wen  = s_rx_valid & !s_loaded;
    assign fifo_we   = s_rx_valid &  s_loaded;
    assign sram_addr = s_loaded ? sm_mem_addr : load_addr;
    assign sram_ren  = s_loaded & sm_read_en;

    always_ff @(posedge clk) begin
        if (rst)           load_addr <= '0;
        else if (sram_wen) load_addr <= load_addr + 1'b1;
    end

    RM_IHPSG13_1P_64x16_c2 u_imem (
        .A_CLK(clk),
        .A_MEN(1'b1),
        .A_WEN(sram_wen),
        .A_REN(sram_ren),
        .A_ADDR(sram_addr),
        .A_DIN(s_rx_data),
        .A_DLY(1'b1),
        .A_DOUT(sram_dout)
    );

    fifo #(
        .DEPTH(FIFO_DEPTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_tx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(s_rx_data),
        .w_en(fifo_we),
        .r_en(sm_tx_pop),
        .d_out(fifo_out),
        .wptr(wptr),
        .rptr(rptr)
    );

    assign fifo_level = wptr - rptr;

    sm_no_smx_instr #(.DATA_WIDTH(DATA_WIDTH)) dut (
        .clk(clk),
        .external_rst(rst),
        .en(1'b0),                         // boot only; nothing executes
        .restart(1'b0),
        .clkdiv_restart(1'b0),
        .imem_loaded(s_loaded),
        .mem_addr(sm_mem_addr),
        .read_en(sm_read_en),
        .instr(sram_dout),
        .tx_data(fifo_out),
        .tx_empty(wptr == rptr),
        .tx_level(3'(fifo_level)),
        .tx_pop(sm_tx_pop),
        .rx_data(sm_rx_data),
        .rx_full(1'b0),
        .rx_level(3'd0),
        .rx_push(sm_rx_push),
        .gpio_in('0),
        .pins_re(pins_re),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .irq_flags(8'd0),
        .irq_set(irq_set),
        .irq_clr(irq_clr)
    );

    // Dumping starts in run_test, after DUMP_AFTER words.
    initial begin
        $dumpfile(`TB_DUMPFILE);
        $timeformat(-9, 1, " ns", 0);     // %t prints ns, not 10 ps ticks
    end

`ifdef SV_TEST
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        setup_test();
        run_test();
        report_results();
    end

    initial begin
        #5ms;
        $error("timeout");
        $finish;
    end

    task automatic check(input logic ok, input string msg);
        if (ok !== 1'b1) begin
            failures++;
            $error("%s", msg);
        end
    endtask

    // ---- The two edges around `loaded` --------------------------------------
    // s_loaded is a flop, so its rising edge is in the NBA region of a clk
    // posedge; sample #1 after that edge.
    initial begin : loaded_monitor
        @(posedge s_loaded);
        check(clk === 1'b1, $sformatf("loaded rose off a clk edge at %0t", $time));
        #1;
        $display("loaded edge   @%0t: pc=%0d rst=%b sram_addr=%0d", $time, dut.pc, dut.rst, sram_addr);
        check(dut.pc === CFG_BASE, $sformatf("loaded edge: pc=%0d, expected 32", dut.pc));
        check(dut.rst === 1'b1, "loaded edge: SM must still be in reset");
        check(sm_mem_addr === CFG_BASE, $sformatf("loaded edge: mem_addr=%0d, expected 32", sm_mem_addr));
        check(sram_addr === CFG_BASE, "loaded edge: SRAM address is not the SM's");
        check(sram_ren === 1'b1, "loaded edge: SRAM read not enabled for the SM");
        check(sram_wen === 1'b0, "loaded edge: SRAM still being written");
        check(u_imem.i_SRAM_1P_behavioral.memory[IMEM_XFER_CNT-1] === words[IMEM_XFER_CNT-1],
              $sformatf("loaded edge: word %0d not written (mem=%h, sent %h)", IMEM_XFER_CNT-1,
                        u_imem.i_SRAM_1P_behavioral.memory[IMEM_XFER_CNT-1], words[IMEM_XFER_CNT-1]));

        @(posedge clk);
        #1;
        $display("next edge     @%0t: pc=%0d rst=%b instr=%h (mem[32]=%h)",
                 $time, dut.pc, dut.rst, sram_dout, words[CFG_BASE]);
        check(dut.pc === CFG_BASE, $sformatf("next edge: pc=%0d, expected 32", dut.pc));
        check(sram_dout === words[CFG_BASE],
              $sformatf("next edge: instr=%h, expected mem[32]=%h", sram_dout, words[CFG_BASE]));
        check(dut.rst === 1'b0, "next edge: SM still in reset");
        check(dut.booting === 1'b1, "next edge: SM not booting");
    end

    // One SPI frame from the master. Returns once the master drops busy.
    task automatic send_word(input logic [DATA_WIDTH-1:0] word);
        @(negedge clk);
        m_tx_data = word;
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
    endtask

    task automatic run_test();
        // 32 instruction slots, then CLKDIV, EXECCTRL, SHIFTCTRL, PINCTRL
        // (low half first). en stays low, so their values only need to be
        // recognizable after boot.
        for (int k = 0; k < CFG_BASE; k++) words[k] = 16'(k * 16'h0101 + 16'h1000);
        words[32] = 16'h8000; words[33] = 16'h0003;   // CLKDIV    0003_8000
        words[34] = 16'hF080; words[35] = 16'h0001;   // EXECCTRL  0001_F080
        words[36] = 16'h0000; words[37] = 16'h000C;   // SHIFTCTRL 000C_0000
        words[38] = 16'h0020; words[39] = 16'h1400;   // PINCTRL   1400_0020

        // ---- program load -----------------------------------------------
        foreach (words[k]) begin
            if (k == DUMP_AFTER) begin
                $display("@%0t: %0d words sent, recording waveforms", $time, k);
                $dumpvars(0, tb_spi_imem_sm);
            end
            send_word(words[k]);
            check(fifo_level === '0, $sformatf("word %0d reached the TX FIFO", k));
            check(s_loaded === (k == IMEM_XFER_CNT-1),
                  $sformatf("loaded=%b after %0d words", s_loaded, k + 1));
        end

        // Boot is 8 cycles; the frame tail after word 40 already covers it,
        // but wait a few more to be safe.
        repeat (4) @(negedge clk);
        check_imem("after load");
        check(dut.booting === 1'b0, "SM still booting");
        check(dut.clkdiv    === {words[33], words[32]}, $sformatf("CLKDIV=%h", dut.clkdiv));
        check(dut.execctrl  === {words[35], words[34]}, $sformatf("EXECCTRL=%h", dut.execctrl));
        check(dut.shiftctrl === {words[37], words[36]}, $sformatf("SHIFTCTRL=%h", dut.shiftctrl));
        check(dut.pinctrl   === {words[39], words[38]}, $sformatf("PINCTRL=%h", dut.pinctrl));

        // ---- bogus word: must go to the FIFO ------------------------------
        send_word(BOGUS);
        @(negedge clk);
        $display("bogus word: fifo level=%0d, fifo[0]=%h", fifo_level, u_tx_fifo.mem[0]);
        check(fifo_level === 1, $sformatf("FIFO level=%0d after bogus word, expected 1", fifo_level));
        check(u_tx_fifo.mem[0] === BOGUS, $sformatf("FIFO holds %h, expected %h", u_tx_fifo.mem[0], BOGUS));
        check(load_addr === 6'(IMEM_XFER_CNT), $sformatf("load_addr=%0d moved after load", load_addr));
        check_imem("after bogus word");
    endtask

    task automatic check_imem(input string when);
        for (int k = 0; k < IMEM_XFER_CNT; k++)
            check(u_imem.i_SRAM_1P_behavioral.memory[k] === words[k],
                  $sformatf("%s: mem[%0d]=%h, sent %h", when, k,
                            u_imem.i_SRAM_1P_behavioral.memory[k], words[k]));
    endtask

    task setup_test();
        rst       = 1;
        cpol      = 0;
        cpha      = 0;
        start     = 0;
        m_tx_data = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    task report_results();
        if (failures == 0)
            $display("SPI -> IMEM -> SM load tests passed");
        else
            $display("SPI -> IMEM -> SM load tests: %0d check(s) failed", failures);
        $finish;
    endtask

`endif
endmodule
