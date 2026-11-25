`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_tx_fifo.fst"
`endif

// Integration: SM <-> TX FIFO (sm_integration.md).
//
// The real sm_no_smx_instr and the real fifo.sv, wired exactly as in
// pio_spi_top: tx_data = head (fall-through read), tx_empty / tx_level from
// the pointers, r_en = tx_pop. The host writes d_in / w_en. Instruction
// memory is a synchronous-read testbench model; nothing else is connected.
//
// Scoreboard (every cycle): a model queue of the words the FIFO accepted
// (writes to a full FIFO are dropped, as fifo.sv does). On every tx_pop,
// tx_data must equal the oldest unpopped word, and the FIFO must not be
// empty. After every edge, the FIFO's level must equal the model's.
//
// Scenarios: PULL block / noblock / ifempty, autopull at thresholds 16 and
// 8 (OUT stalls on an empty FIFO), back-to-back pops, host writes beyond
// depth 4, and MOV x, STATUS against tx_level.
module tb_sm_tx_fifo;
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

    // TX FIFO, wired as in pio_spi_top
    logic          host_we;
    logic [W-1:0]  host_wdata;
    wire  [W-1:0]  tx_data;
    wire           tx_pop;
    wire  [DB:0]   tx_wptr, tx_rptr;
    wire  [DB:0]   tx_count = tx_wptr - tx_rptr;
    wire           tx_empty = (tx_count == '0);

    fifo #(.DEPTH(DEPTH), .DATA_WIDTH(W)) u_tx_fifo (
        .clk(clk), .rst(rst),
        .d_in(host_wdata), .w_en(host_we),
        .r_en(tx_pop), .d_out(), .head(tx_data),
        .wptr(tx_wptr), .rptr(tx_rptr)
    );

    wire [W-1:0] rx_data, pins_re, pins_we, pins_wdata, dirs_we, dirs_wdata;
    wire         rx_push;
    wire [7:0]   irq_set, irq_clr;

    sm_no_smx_instr #(.DATA_WIDTH(W)) dut (
        .clk(clk), .external_rst(sm_rst), .imem_loaded(1'b1),
        .en(en), .restart(1'b0), .clkdiv_restart(1'b0),
        .mem_addr(mem_addr), .read_en(read_en), .instr(instr),
        .tx_data(tx_data), .tx_empty(tx_empty), .tx_level(3'(tx_count)), .tx_pop(tx_pop),
        .rx_data(rx_data), .rx_full(1'b0), .rx_level(3'd0), .rx_push(rx_push),
        .gpio_in('0), .pins_re(pins_re), .pins_we(pins_we), .pins_wdata(pins_wdata),
        .dirs_we(dirs_we), .dirs_wdata(dirs_wdata), .gpio_fault(1'b0),
        .irq_flags(8'd0), .irq_set(irq_set), .irq_clr(irq_clr)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_tx_fifo);
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
    int pops;
    int pop_cycle [$];          // cycle number of every pop

    int pre;                    // model level before this edge
    always @(posedge clk) begin
        cyc++;
        if (rst) begin
            model.delete();
        end else begin
            pre = model.size();
            if (tx_pop) begin
                if (pre == 0) begin
                    check(0, $sformatf("cycle %0d: tx_pop on an empty FIFO", cyc));
                end else begin
                    check(tx_data === model[0],
                          $sformatf("cycle %0d: popped %h, oldest word is %h", cyc, tx_data, model[0]));
                    void'(model.pop_front());
                end
                pops++;
                pop_cycle.push_back(cyc);
            end
            if (host_we && pre < DEPTH)            // fifo.sv drops writes when full
                model.push_back(host_wdata);
        end
    end

    always @(negedge clk)
        if (!rst)
            check(tx_count == model.size(),
                  $sformatf("cycle %0d: FIFO level %0d, model %0d", cyc, tx_count, model.size()));

    // ------------------------------------------------------------------------
    // Harness
    // ------------------------------------------------------------------------

    // Reset everything, fill the program with self-jumps and default config.
    // The SM stays in reset until boot().
    task automatic reset_all();
        rst = 1;
        sm_rst = 1;
        en = 0;
        host_we = 0;
        host_wdata = '0;
        for (int i = 0; i < 32; i++)
            imem[i] = i_jmp(C_ALWAYS, 5'(i));
        clkdiv    = clkdiv_f(1, 0);
        execctrl  = execctrl_f(0, 0, 0, 0, 31, 0, 0, 0);
        shiftctrl = shiftctrl_f(16, 16, 1, 1, 0, 0);
        pinctrl   = '0;
        step(2);
        rst = 0;
        pops = 0;
        pop_cycle.delete();
    endtask

    // Write the config to 32-39 and release the SM: 8 boot cycles, then the
    // PC is 0 and the next enabled cycle runs the program.
    task automatic boot();
        {imem[33], imem[32]} = clkdiv;
        {imem[35], imem[34]} = execctrl;
        {imem[37], imem[36]} = shiftctrl;
        {imem[39], imem[38]} = pinctrl;
        step(1);                                  // SRAM model reads 32 in reset
        sm_rst = 0;
        step(8);
        check(dut.pc === 6'd0, $sformatf("boot: pc=%0d, expected 0", dut.pc));
    endtask

    // Host writes one word (one cycle).
    task automatic host_write(input [W-1:0] w);
        host_we = 1;
        host_wdata = w;
        step(1);
        host_we = 0;
    endtask

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    // PULL block stalls on an empty FIFO and completes the cycle after the
    // host's write, with that word in the OSR.
    task automatic test_pull_block();
        int wcyc;
        reset_all();
        imem[0] = i_pull(0, 1);                    // pull block
        imem[1] = i_mov(MD_X, MOP_NONE, MS_OSR);   // mov x, osr
        boot();
        en = 1;
        step(6);
        check(dut.pc === 6'd0 && dut.stall === 1'b1, "pull block: not stalled on empty FIFO");
        check(pops == 0, "pull block: popped an empty FIFO");
        wcyc = cyc + 1;                            // the write lands on the next edge
        host_write(16'hBEEF);
        step(3);
        check(pops == 1, $sformatf("pull block: %0d pops, expected 1", pops));
        if (pop_cycle.size() == 1)
            check(pop_cycle[0] == wcyc + 1,
                  $sformatf("pull block: popped %0d cycles after the write, expected 1", pop_cycle[0] - wcyc));
        check(dut.x === 16'hBEEF, $sformatf("pull block: x=%h, expected beef", dut.x));
    endtask

    // PULL noblock on an empty FIFO copies X and does not pop.
    task automatic test_pull_noblock();
        reset_all();
        imem[0] = i_set(S_X, 21);
        imem[1] = i_pull(0, 0);                    // pull noblock
        imem[2] = i_mov(MD_Y, MOP_NONE, MS_OSR);
        boot();
        en = 1;
        step(6);
        check(dut.y === 16'd21, $sformatf("pull noblock: y=%h, expected X = 21", dut.y));
        check(pops == 0, "pull noblock: popped an empty FIFO");
    endtask

    // PULL ifempty: no-op until PULL_THRESH (8) bits have been shifted out.
    task automatic test_pull_ifempty();
        reset_all();
        shiftctrl = shiftctrl_f(8, 16, 1, 1, 0, 0);
        host_write(16'h1111);
        host_write(16'h2222);
        host_write(16'h3333);
        imem[0] = i_pull(0, 1);                    // pull block: OSR = 1111
        imem[1] = i_out(O_NULL, 4);
        imem[2] = i_pull(1, 1);                    // 4 < 8: no-op
        imem[3] = i_mov(MD_X, MOP_NONE, MS_OSR);
        imem[4] = i_out(O_NULL, 4);
        imem[5] = i_pull(1, 1);                    // 8 >= 8: pulls 2222
        imem[6] = i_mov(MD_Y, MOP_NONE, MS_OSR);
        boot();
        en = 1;
        step(12);
        check(pops == 2, $sformatf("pull ifempty: %0d pops, expected 2", pops));
        check(dut.x === 16'h0111, $sformatf("pull ifempty: x=%h, expected 0111 (no pull)", dut.x));
        check(dut.y === 16'h2222, $sformatf("pull ifempty: y=%h, expected 2222", dut.y));
        check(tx_count == 1, $sformatf("pull ifempty: FIFO level %0d, expected 1", tx_count));
    endtask

    // Autopull, threshold 16: OUT stalls on an empty FIFO and resumes once
    // the host writes.
    task automatic test_autopull_16();
        reset_all();
        shiftctrl = shiftctrl_f(16, 16, 1, 1, 1, 0);
        imem[0] = i_out(O_X, 16);
        imem[1] = i_out(O_Y, 16);
        boot();
        en = 1;
        step(5);
        check(dut.pc === 6'd0 && dut.stall === 1'b1, "autopull 16: OUT not stalled on empty FIFO");
        host_write(16'hA001);
        step(3);
        check(dut.x === 16'hA001, $sformatf("autopull 16: x=%h, expected a001", dut.x));
        check(dut.pc === 6'd1 && dut.stall === 1'b1, "autopull 16: second OUT not stalled");
        host_write(16'hA002);
        step(3);
        check(dut.y === 16'hA002, $sformatf("autopull 16: y=%h, expected a002", dut.y));
        check(pops == 2, $sformatf("autopull 16: %0d pops, expected 2", pops));
    endtask

    // Autopull, threshold 8: each 16-bit word supplies only 8 bits (LSBs,
    // shifting right) before the next refill.
    task automatic test_autopull_8();
        reset_all();
        shiftctrl = shiftctrl_f(8, 16, 1, 1, 1, 0);
        host_write(16'hB2B1);
        host_write(16'hC2C1);
        imem[0] = i_out(O_X, 8);
        imem[1] = i_out(O_Y, 8);
        boot();
        en = 1;
        step(8);
        check(dut.x === 16'h00B1, $sformatf("autopull 8: x=%h, expected 00b1", dut.x));
        check(dut.y === 16'h00C1, $sformatf("autopull 8: y=%h, expected 00c1 (next word)", dut.y));
        check(pops == 2, $sformatf("autopull 8: %0d pops, expected 2", pops));
    endtask

    // Four PULLs in a row pop on four consecutive cycles, in order.
    task automatic test_back_to_back();
        reset_all();
        for (int i = 0; i < 4; i++)
            host_write(16'hD000 + 16'(i));
        for (int i = 0; i < 4; i++)
            imem[i] = i_pull(0, 1);
        boot();
        en = 1;
        step(8);
        check(pops == 4, $sformatf("back-to-back: %0d pops, expected 4", pops));
        for (int i = 1; i < pop_cycle.size(); i++)
            check(pop_cycle[i] == pop_cycle[i - 1] + 1, "back-to-back: pops not on consecutive cycles");
        check(dut.osr_q === 16'hD003, $sformatf("back-to-back: OSR=%h, expected d003", dut.osr_q));
        check(tx_empty, "back-to-back: FIFO not empty");
    endtask

    // Writes beyond depth 4 are dropped by the FIFO: the SM sees only the
    // first four, and a fifth PULL stalls.
    task automatic test_overflow();
        reset_all();
        for (int i = 0; i < 5; i++)
            host_write(16'hE000 + 16'(i));
        check(tx_count == 4, $sformatf("overflow: FIFO level %0d, expected 4", tx_count));
        for (int i = 0; i < 5; i++)
            imem[i] = i_pull(0, 1);
        boot();
        en = 1;
        step(10);
        check(pops == 4, $sformatf("overflow: %0d pops, expected 4", pops));
        check(dut.pc === 6'd4 && dut.stall === 1'b1, "overflow: fifth PULL not stalled");
        check(dut.osr_q === 16'hE003, $sformatf("overflow: OSR=%h, expected e003", dut.osr_q));
    endtask

    // MOV x, STATUS with STATUS_SEL = TX: all ones when tx_level < STATUS_N.
    task automatic test_status(input [3:0] n);
        for (int k = 0; k <= DEPTH; k++) begin
            reset_all();
            execctrl = execctrl_f(0, 0, 0, 0, 31, 0, 0, n);
            for (int i = 0; i < k; i++)
                host_write(16'(i));
            imem[0] = i_mov(MD_X, MOP_NONE, MS_STATUS);
            boot();
            en = 1;
            step(3);
            check(dut.x === ((k < n) ? 16'hFFFF : 16'h0000),
                  $sformatf("status: level %0d, STATUS_N %0d: x=%h", k, n, dut.x));
        end
    endtask

    initial begin
        test_pull_block();
        test_pull_noblock();
        test_pull_ifempty();
        test_autopull_16();
        test_autopull_8();
        test_back_to_back();
        test_overflow();
        test_status(2);
        test_status(4);

        if (failures == 0) begin
            $display("SM <-> TX FIFO integration test passed");
            $finish;
        end else
            $fatal(1, "SM <-> TX FIFO integration test: %0d check(s) failed", failures);
    end

    initial begin
        #2ms;
        $fatal(1, "timeout");
    end
`endif
endmodule
