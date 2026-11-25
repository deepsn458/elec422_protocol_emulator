`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_rx_fifo.fst"
`endif

// Integration: SM <-> RX FIFO (sm_integration.md).
//
// The real sm_no_smx_instr and the real fifo.sv, wired exactly as in
// pio_spi_top: d_in = rx_data, w_en = rx_push, rx_full / rx_level from the
// pointers. The host pops with r_en and reads head. Instruction memory is a
// synchronous-read testbench model; the TX FIFO input is tied empty.
//
// Scoreboard (every cycle): a model queue of the words the SM pushed. The SM
// must never push into a full FIFO. On every host pop, head must equal the
// oldest pushed word. After every edge, the FIFO's level must equal the
// model's.
//
// Scenarios: PUSH block (stalls on full, resumes after a host pop),
// PUSH noblock (drops on full and clears the ISR), PUSH iffull, autopush at
// thresholds 16 and 8 (IN stalls on full), and MOV x, STATUS against
// rx_level.
module tb_sm_rx_fifo;
    localparam int W     = 16;
    localparam int DEPTH = 4;
    localparam int DB    = $clog2(DEPTH);

    logic clk, rst, sm_rst, en;
    logic [31:0] clkdiv, execctrl, shiftctrl, pinctrl;

    // Instruction memory model: synchronous read, like the IHP SRAM.
    logic [15:0] imem [0:63];
    logic [15:0] instr;
    wire  [5:0]  mem_addr;
    wire         read_en;
    always @(posedge clk)
        if (read_en)
            instr <= imem[mem_addr];

    // RX FIFO, wired as in pio_spi_top
    logic          host_pop;
    wire  [W-1:0]  rx_head;
    wire  [W-1:0]  rx_data;
    wire           rx_push;
    wire  [DB:0]   rx_wptr, rx_rptr;
    wire  [DB:0]   rx_count = rx_wptr - rx_rptr;
    wire           rx_empty = (rx_count == '0);
    wire           rx_full  = (rx_count == (DB+1)'(DEPTH));

    fifo #(.DEPTH(DEPTH), .DATA_WIDTH(W)) u_rx_fifo (
        .clk(clk), .rst(rst),
        .d_in(rx_data), .w_en(rx_push),
        .r_en(host_pop), .d_out(), .head(rx_head),
        .wptr(rx_wptr), .rptr(rx_rptr)
    );

    wire [W-1:0] pins_re, pins_we, pins_wdata, dirs_we, dirs_wdata;
    wire         tx_pop;
    wire [7:0]   irq_set, irq_clr;

    sm_no_smx_instr #(.DATA_WIDTH(W)) dut (
        .clk(clk), .external_rst(sm_rst), .imem_loaded(1'b1),
        .en(en), .restart(1'b0), .clkdiv_restart(1'b0),
        .mem_addr(mem_addr), .read_en(read_en), .instr(instr),
        .tx_data('0), .tx_empty(1'b1), .tx_level(3'd0), .tx_pop(tx_pop),
        .rx_data(rx_data), .rx_full(rx_full), .rx_level(3'(rx_count)), .rx_push(rx_push),
        .gpio_in('0), .pins_re(pins_re), .pins_we(pins_we), .pins_wdata(pins_wdata),
        .dirs_we(dirs_we), .dirs_wdata(dirs_wdata), .gpio_fault(1'b0),
        .irq_flags(8'd0), .irq_set(irq_set), .irq_clr(irq_clr)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_rx_fifo);
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
    // Scoreboard
    // ------------------------------------------------------------------------
    logic [W-1:0] model [$];
    int pushes;
    int push_cycle [$];         // cycle number of every push
    int pre;                    // model level before this edge

    always @(posedge clk) begin
        cyc++;
        if (rst) begin
            model.delete();
        end else begin
            pre = model.size();
            if (host_pop && pre > 0) begin          // fifo.sv ignores pops when empty
                check(rx_head === model[0],
                      $sformatf("cycle %0d: host read %h, oldest word is %h", cyc, rx_head, model[0]));
                void'(model.pop_front());
            end
            if (rx_push) begin
                check(pre < DEPTH, $sformatf("cycle %0d: rx_push into a full FIFO", cyc));
                if (pre < DEPTH)
                    model.push_back(rx_data);
                pushes++;
                push_cycle.push_back(cyc);
            end
        end
    end

    always @(negedge clk)
        if (!rst)
            check(rx_count == model.size(),
                  $sformatf("cycle %0d: FIFO level %0d, model %0d", cyc, rx_count, model.size()));

    // ------------------------------------------------------------------------
    // Harness
    // ------------------------------------------------------------------------

    task automatic reset_all();
        rst = 1;
        sm_rst = 1;
        en = 0;
        host_pop = 0;
        for (int i = 0; i < 32; i++)
            imem[i] = i_jmp(C_ALWAYS, 5'(i));
        clkdiv    = clkdiv_f(1, 0);
        execctrl  = execctrl_f(0, 0, 0, 0, 31, 0, 0, 0);
        shiftctrl = shiftctrl_f(16, 16, 1, 1, 0, 0);
        pinctrl   = '0;
        step(2);
        rst = 0;
        pushes = 0;
        push_cycle.delete();
    endtask

    task automatic boot();
        {imem[33], imem[32]} = clkdiv;
        {imem[35], imem[34]} = execctrl;
        {imem[37], imem[36]} = shiftctrl;
        {imem[39], imem[38]} = pinctrl;
        step(1);
        sm_rst = 0;
        step(8);
        check(dut.pc === 6'd0, $sformatf("boot: pc=%0d, expected 0", dut.pc));
    endtask

    // Host reads the oldest word (fall-through head) and pops it.
    task automatic host_read(output [W-1:0] w);
        w = rx_head;
        host_pop = 1;
        step(1);
        host_pop = 0;
    endtask

    // Host reads n words and checks them against exp[0..n-1]. (exp is
    // module-level: Icarus cannot pass unpacked arrays to tasks.)
    logic [W-1:0] exp [8];
    task automatic expect_words(input int n, input string what);
        logic [W-1:0] w;
        check(rx_count == n, $sformatf("%s: FIFO level %0d, expected %0d", what, rx_count, n));
        for (int i = 0; i < n; i++) begin
            host_read(w);
            check(w === exp[i], $sformatf("%s: word %0d = %h, expected %h", what, i, w, exp[i]));
        end
    endtask

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    // Program: five times {set x, k; in x, 16; push <blk>}, then jmp self.
    task automatic five_pushes(input blk);
        for (int k = 0; k < 5; k++) begin
            imem[3 * k]     = i_set(S_X, 5'(k + 1));
            imem[3 * k + 1] = i_in(IN_X, 16);
            imem[3 * k + 2] = i_push(0, blk);
        end
        imem[15] = i_mov(MD_Y, MOP_NONE, MS_ISR);
    endtask

    // PUSH block: the fifth push stalls on a full FIFO and completes the
    // cycle after the host pops.
    task automatic test_push_block();
        logic [W-1:0] w;
        int pcyc;
        reset_all();
        five_pushes(1);
        boot();
        en = 1;
        step(20);
        check(pushes == 4, $sformatf("push block: %0d pushes before the stall, expected 4", pushes));
        check(dut.pc === 6'd14 && dut.stall === 1'b1, "push block: fifth PUSH not stalled on full FIFO");
        pcyc = cyc + 1;                             // the pop lands on the next edge
        host_read(w);
        check(w === 16'd1, $sformatf("push block: first word %h, expected 1", w));
        step(2);
        check(pushes == 5, $sformatf("push block: %0d pushes after the pop, expected 5", pushes));
        if (push_cycle.size() == 5)
            check(push_cycle[4] == pcyc + 1,
                  $sformatf("push block: pushed %0d cycles after the pop, expected 1", push_cycle[4] - pcyc));
        exp = '{16'd2, 16'd3, 16'd4, 16'd5, 0, 0, 0, 0};
        expect_words(4, "push block");
    endtask

    // PUSH noblock: the fifth push finds the FIFO full, is dropped, and still
    // clears the ISR.
    task automatic test_push_noblock();
        reset_all();
        five_pushes(0);
        boot();
        en = 1;
        step(24);
        check(pushes == 4, $sformatf("push noblock: %0d pushes, expected 4", pushes));
        check(dut.pc === 6'd16, $sformatf("push noblock: pc=%0d, expected 16 (no stall)", dut.pc));
        check(dut.y === '0, $sformatf("push noblock: ISR=%h after the dropped push, expected 0", dut.y));
        exp = '{16'd1, 16'd2, 16'd3, 16'd4, 0, 0, 0, 0};
        expect_words(4, "push noblock");
    endtask

    // PUSH iffull (PUSH_THRESH = 8): no-op at 4 bits, pushes at 8.
    task automatic test_push_iffull();
        reset_all();
        shiftctrl = shiftctrl_f(16, 8, 1, 1, 0, 0);
        imem[0] = i_set(S_X, 3);
        imem[1] = i_in(IN_X, 4);
        imem[2] = i_push(1, 1);                     // 4 < 8: no-op
        imem[3] = i_in(IN_X, 4);
        imem[4] = i_push(1, 1);                     // 8: push
        boot();
        en = 1;
        step(4);
        check(pushes == 0, "push iffull: pushed below the threshold");
        step(4);
        check(pushes == 1, $sformatf("push iffull: %0d pushes, expected 1", pushes));
        exp = '{16'h3300, 0, 0, 0, 0, 0, 0, 0};       // IN shifts right: data at the top
        expect_words(1, "push iffull");
    endtask

    // Autopush, threshold 16: IN pushes every 16 bits; with the FIFO full,
    // IN stalls until the host pops.
    task automatic test_autopush_16();
        logic [W-1:0] w;
        reset_all();
        shiftctrl = shiftctrl_f(16, 16, 1, 1, 0, 1);
        imem[0] = i_set(S_X, 7);
        imem[1] = i_in(IN_X, 16);
        imem[2] = i_jmp(C_ALWAYS, 1);
        boot();
        en = 1;
        step(16);
        check(pushes == 4, $sformatf("autopush 16: %0d pushes, expected 4", pushes));
        check(dut.pc === 6'd1 && dut.stall === 1'b1, "autopush 16: IN not stalled on full FIFO");
        host_read(w);
        step(2);
        check(pushes == 5, $sformatf("autopush 16: %0d pushes after a pop, expected 5", pushes));
        exp = '{16'd7, 16'd7, 16'd7, 16'd7, 0, 0, 0, 0};
        expect_words(4, "autopush 16");
    endtask

    // Autopush, threshold 8: each push carries 8 bits, at the top of the ISR.
    task automatic test_autopush_8();
        reset_all();
        shiftctrl = shiftctrl_f(16, 8, 1, 1, 0, 1);
        imem[0] = i_set(S_X, 5);
        imem[1] = i_in(IN_X, 8);
        imem[2] = i_set(S_X, 6);
        imem[3] = i_in(IN_X, 8);
        boot();
        en = 1;
        step(6);
        exp = '{16'h0500, 16'h0600, 0, 0, 0, 0, 0, 0};
        expect_words(2, "autopush 8");
    endtask

    // MOV x, STATUS with STATUS_SEL = RX: all ones when rx_level < STATUS_N.
    task automatic test_status(input [3:0] n);
        for (int k = 0; k <= DEPTH; k++) begin
            reset_all();
            execctrl = execctrl_f(0, 0, 0, 0, 31, 0, 1, n);
            for (int i = 0; i < k; i++)
                imem[i] = i_push(0, 0);                 // push the (empty) ISR
            imem[k] = i_mov(MD_X, MOP_NONE, MS_STATUS);
            boot();
            en = 1;
            step(k + 3);
            check(rx_count == k, $sformatf("status: level %0d, expected %0d", rx_count, k));
            check(dut.x === ((k < n) ? 16'hFFFF : 16'h0000),
                  $sformatf("status: level %0d, STATUS_N %0d: x=%h", k, n, dut.x));
        end
    endtask

    initial begin
        test_push_block();
        test_push_noblock();
        test_push_iffull();
        test_autopush_16();
        test_autopush_8();
        test_status(2);
        test_status(4);

        if (failures == 0) begin
            $display("SM <-> RX FIFO integration test passed");
            $finish;
        end else
            $fatal(1, "SM <-> RX FIFO integration test: %0d check(s) failed", failures);
    end

    initial begin
        #2ms;
        $fatal(1, "timeout");
    end
`endif
endmodule
