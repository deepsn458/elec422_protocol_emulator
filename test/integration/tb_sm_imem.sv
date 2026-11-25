`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_imem.fst"
`endif

// Integration: SM <-> instruction memory (sm_integration.md).
//
// The real sm_no_smx_instr and the IHP 64x16 SRAM model, wired exactly as
// in pio_spi_top: while `loaded` is low the testbench writes the image
// through the SRAM's write port (as spi_slave does) and the SM is held in
// reset; once `loaded` rises the SRAM address and read enable come from
// the SM (A_ADDR = mem_addr, A_REN = loaded & read_en) and the SM boots.
// The FIFOs and GPIOs are tied off.
//
// Monitor (every cycle the SM is out of reset, boot included): instr is
// the word at the current PC, instr === memory[pc]. That is the whole
// synchronous-fetch contract: mem_addr is the NEXT PC, so the SRAM's
// registered read lines up with the PC with no lost cycles.
//
// Scenarios: release on `loaded` and boot from 32-39; every way the PC
// changes (increment, JMP taken / not taken, MOV PC, OUT PC, wrap, 31 -> 0)
// against an expected trace; every way it holds (stalled PULL, delay
// cycles, clock divisor 3 and 2.5, en low); SM_RESTART does not reboot;
// rst and a reload with a different image.
module tb_sm_imem;
    localparam int W = 16;
    localparam int IMAGE_WORDS = 40;
    localparam logic [5:0] CFG_BASE = 6'd32;

    logic clk, rst, en, restart, loaded;

    // Load port (stands in for spi_slave) and SRAM steering, as in pio_spi_top
    logic        load_we;
    logic [5:0]  load_addr;
    logic [15:0] load_data;
    wire  [5:0]  sm_mem_addr;
    wire         sm_read_en;
    wire  [15:0] instr;
    wire  [5:0]  imem_addr = loaded ? sm_mem_addr : load_addr;
    wire         imem_ren  = loaded & sm_read_en;

    RM_IHPSG13_1P_64x16_c2 u_imem (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(load_we), .A_REN(imem_ren),
        .A_ADDR(imem_addr), .A_DIN(load_data), .A_DLY(1'b1), .A_DOUT(instr)
    );

    wire [W-1:0] rx_data, pins_re, pins_we, pins_wdata, dirs_we, dirs_wdata;
    wire         rx_push, tx_pop;
    wire [7:0]   irq_set, irq_clr;

    sm_no_smx_instr #(.DATA_WIDTH(W)) dut (
        .clk(clk), .external_rst(rst), .imem_loaded(loaded),
        .en(en), .restart(restart), .clkdiv_restart(1'b0),
        .mem_addr(sm_mem_addr), .read_en(sm_read_en), .instr(instr),
        .tx_data('0), .tx_empty(1'b1), .tx_level(3'd0), .tx_pop(tx_pop),
        .rx_data(rx_data), .rx_full(1'b0), .rx_level(3'd0), .rx_push(rx_push),
        .gpio_in('0), .pins_re(pins_re), .pins_we(pins_we), .pins_wdata(pins_wdata),
        .dirs_we(dirs_we), .dirs_wdata(dirs_wdata), .gpio_fault(1'b0),
        .irq_flags(8'd0), .irq_set(irq_set), .irq_clr(irq_clr)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_imem);
    end

`ifdef SV_TEST
    `include "sm_tb_common.svh"

    initial clk = 0;
    always #5 clk = ~clk;

    int failures = 0;
    int cyc = 0;

    task automatic check(input logic ok, input string msg);
        if (ok !== 1'b1) begin
            failures++;
            $error("%s", msg);
        end
    endtask

    // Inputs change 1 ns after the rising edge.
    task automatic step(input int n);
        repeat (n) @(posedge clk);
        #1;
    endtask

    // ------------------------------------------------------------------------
    // The image being loaded, and the monitor
    // ------------------------------------------------------------------------
    logic [15:0] img [IMAGE_WORDS];       // what the testbench wrote
    logic [31:0] clkdiv, execctrl, shiftctrl, pinctrl;

    int fetch_checks;
    always @(negedge clk) begin
        if (!dut.rst) begin
            fetch_checks++;
            check(instr === img[dut.pc],
                  $sformatf("cycle %0d: pc=%0d, instr=%h, memory[pc]=%h", cyc, dut.pc, instr, img[dut.pc]));
        end
    end

    // Trace of the PC of every completed instruction.
    int trace [$];
    always @(posedge clk) begin
        cyc++;
        if (!dut.rst && dut.done)
            trace.push_back(dut.pc);
    end

    // ------------------------------------------------------------------------
    // Harness
    // ------------------------------------------------------------------------

    // Self-jumps everywhere, default config.
    task automatic new_image();
        for (int i = 0; i < 32; i++)
            img[i] = i_jmp(C_ALWAYS, 5'(i));
        clkdiv    = clkdiv_f(1, 0);
        execctrl  = execctrl_f(0, 0, 0, 0, 31, 0, 0, 0);
        shiftctrl = shiftctrl_f(16, 16, 1, 1, 0, 0);
        pinctrl   = '0;
    endtask

    // rst, write the image through the SRAM's write port with `loaded` low,
    // then raise `loaded`: the SM leaves reset one cycle later and boots
    // (8 cycles). Returns with the PC at 0.
    task automatic load_and_boot();
        {img[33], img[32]} = clkdiv;
        {img[35], img[34]} = execctrl;
        {img[37], img[36]} = shiftctrl;
        {img[39], img[38]} = pinctrl;
        rst = 1;
        loaded = 0;
        en = 0;
        restart = 0;
        load_we = 0;
        step(2);
        rst = 0;
        for (int i = 0; i < IMAGE_WORDS; i++) begin
            load_we = 1;
            load_addr = 6'(i);
            load_data = img[i];
            step(1);
            check(dut.rst === 1'b1 && dut.pc === CFG_BASE,
                  $sformatf("load: SM not held at 32 while loading (pc=%0d)", dut.pc));
        end
        load_we = 0;
        for (int i = 0; i < IMAGE_WORDS; i++)
            check(u_imem.i_SRAM_1P_behavioral.memory[i] === img[i],
                  $sformatf("load: memory[%0d]=%h, wrote %h", i, u_imem.i_SRAM_1P_behavioral.memory[i], img[i]));
        // Driving `loaded` 1 ns after an edge is the same as spi_slave's flop
        // rising on that edge. The SM is still in reset until the next edge,
        // and the SRAM, now addressed by the SM, reads 32 on that edge.
        loaded = 1;
        #1;
        check(dut.rst === 1'b1, "release: SM left reset on the same edge as loaded");
        check(imem_addr === CFG_BASE && imem_ren === 1'b1,
              $sformatf("release: SRAM address %0d (ren %b), expected the SM reading 32", imem_addr, imem_ren));
        step(1);
        check(dut.rst === 1'b0 && dut.booting === 1'b1 && dut.pc === CFG_BASE,
              "release: SM not booting at 32 one cycle after loaded");
        check(instr === img[32], $sformatf("release: instr=%h, expected memory[32]=%h", instr, img[32]));
        step(8);
        check(dut.pc === 6'd0 && dut.booting === 1'b0, $sformatf("boot: pc=%0d after 8 cycles, expected 0", dut.pc));
        check(dut.clkdiv === clkdiv && dut.execctrl === execctrl &&
              dut.shiftctrl === shiftctrl && dut.pinctrl === pinctrl, "boot: config registers do not match 32-39");
        trace.delete();
    endtask

    // Expected trace (module-level: Icarus cannot pass unpacked arrays).
    int exp [16];
    task automatic check_trace(input string what, input int n);
        check(trace.size() >= n, $sformatf("%s: only %0d instructions completed", what, trace.size()));
        for (int i = 0; i < n && i < trace.size(); i++)
            check(trace[i] == exp[i], $sformatf("%s: step %0d at pc %0d, expected %0d", what, i, trace[i], exp[i]));
    endtask

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    // Every way the PC moves, with wrap off (31 -> 0).
    task automatic test_pc_moves();
        new_image();
        img[0]  = i_set(S_X, 0);
        img[1]  = i_jmp(C_NOT_X, 3);              // taken
        img[2]  = NOP;
        img[3]  = i_jmp(C_X_DEC, 2);              // not taken (x was 0)
        img[4]  = i_set(S_Y, 7);
        img[5]  = i_mov(MD_PC, MOP_NONE, MS_Y);   // MOV PC -> 7
        img[6]  = NOP;
        img[7]  = i_set(S_X, 29);
        img[8]  = i_mov(MD_OSR, MOP_NONE, MS_X);
        img[9]  = i_out(O_PC, 5);                 // OUT PC -> 29
        img[29] = NOP;
        img[30] = NOP;
        img[31] = NOP;                            // 31 -> 0
        load_and_boot();
        en = 1;
        step(14);
        exp = '{0, 1, 3, 4, 5, 7, 8, 9, 29, 30, 31, 0, 1, 3, 0, 0};
        check_trace("pc moves", 14);
    endtask

    // Wrap 3 -> 1.
    task automatic test_wrap();
        new_image();
        execctrl = execctrl_f(0, 0, 0, 0, 3, 1, 0, 0);
        img[0] = NOP;
        img[1] = NOP;
        img[2] = NOP;
        img[3] = NOP;
        load_and_boot();
        en = 1;
        step(10);
        exp = '{0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 0, 0, 0, 0, 0, 0};
        check_trace("wrap", 10);
    endtask

    // Holds: the PC stays put and the SRAM keeps returning the same word.
    task automatic test_holds();
        // Stalled PULL (TX FIFO tied empty).
        new_image();
        img[0] = i_pull(0, 1);
        load_and_boot();
        en = 1;
        step(10);
        check(dut.pc === 6'd0 && dut.stall === 1'b1 && trace.size() == 0, "hold: PULL not stalled at 0");

        // Delay: nop [3] runs every 4 cycles.
        new_image();
        img[0] = dss(NOP, 3);
        img[1] = dss(i_jmp(C_ALWAYS, 0), 3);
        load_and_boot();
        en = 1;
        step(16);
        check(trace.size() == 4, $sformatf("hold: %0d instructions in 16 cycles with [3] delays, expected 4", trace.size()));

        // en low: nothing runs.
        new_image();
        img[0] = NOP;
        load_and_boot();
        step(10);
        check(dut.pc === 6'd0 && trace.size() == 0, "hold: SM ran with en low");
    endtask

    // Clock divisor: instructions complete only on divider ticks.
    task automatic test_clkdiv(input [15:0] div_int, input [7:0] div_frac, input int cycles, input int exp_n);
        new_image();
        clkdiv = clkdiv_f(div_int, div_frac);
        for (int i = 0; i < 31; i++)
            img[i] = NOP;
        load_and_boot();
        en = 1;
        step(cycles);
        check(trace.size() == exp_n, $sformatf("clkdiv %0d.%0d: %0d instructions in %0d cycles, expected %0d",
                                               div_int, div_frac, trace.size(), cycles, exp_n));
    endtask

    // SM_RESTART keeps the loaded config and does not reboot.
    task automatic test_restart();
        new_image();
        img[0] = NOP;
        img[1] = NOP;
        img[2] = i_jmp(C_ALWAYS, 2);
        load_and_boot();
        en = 1;
        step(5);
        restart = 1;
        step(1);
        restart = 0;
        step(2);
        check(dut.booting === 1'b0, "restart: SM rebooted");
        check(dut.pc < 6'd32, $sformatf("restart: pc=%0d", dut.pc));
    endtask

    // rst and reload with a different image and config: the new config is
    // used and only new words are fetched (the monitor checks every fetch).
    task automatic test_reload();
        new_image();
        img[0] = i_set(S_X, 1);
        load_and_boot();
        en = 1;
        step(4);
        check(dut.x === 16'd1, "reload: first image did not run");

        new_image();
        execctrl = execctrl_f(0, 0, 0, 0, 1, 0, 0, 0);    // wrap 1 -> 0
        img[0] = i_set(S_X, 2);
        img[1] = NOP;
        load_and_boot();
        en = 1;
        step(6);
        check(dut.x === 16'd2, "reload: second image did not run");
        exp = '{0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
        check_trace("reload", 6);
    endtask

    initial begin
        rst = 1;
        loaded = 0;
        en = 0;
        restart = 0;
        load_we = 0;
        load_addr = '0;
        load_data = '0;
        for (int i = 0; i < IMAGE_WORDS; i++)
            img[i] = '0;

        test_pc_moves();
        test_wrap();
        test_holds();
        test_clkdiv(3, 0, 30, 10);
        test_clkdiv(2, 8'h80, 30, 12);
        test_restart();
        test_reload();

        check(fetch_checks > 200, $sformatf("monitor only checked %0d fetches", fetch_checks));
        if (failures == 0) begin
            $display("SM <-> instruction memory integration test passed (%0d fetches checked)", fetch_checks);
            $finish;
        end else
            $fatal(1, "SM <-> instruction memory integration test: %0d check(s) failed", failures);
    end

    initial begin
        #2ms;
        $fatal(1, "timeout");
    end
`endif
endmodule
