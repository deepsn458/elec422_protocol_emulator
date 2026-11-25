`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_gpio.fst"
`endif

// Integration: SM <-> GPIO controller (sm_integration.md).
//
// The real sm_no_smx_instr and the real gpio_controller, wired exactly as
// in pio_spi_top (pins_we/wdata, dirs_we/wdata, pins_re, gpio_in,
// gpio_fault), with the default pin map: GPIO 0-3 input only, 4-11
// bidirectional, 12-15 output only. SAFE_OUT = A000 so the safe level is
// visible. Pads loop back: a driven pad reads its own level, others read
// ext_in. Instruction memory is a synchronous-read testbench model; the
// FIFOs are tied off.
//
// Monitors (every cycle):
//   * gpio_in = pad_in on readable GPIOs (input or bidirectional), else 0;
//   * the controller's pin registers follow the SM's write masks exactly,
//     except on a fault cycle or while the sticky fault is set, when they
//     must not change at all;
//   * no gpio_fault outside the fault tests.
//
// Scenarios: SET / OUT / MOV PINS and PINDIRS and side-set (to pins and to
// pindirs) reach the pads; IN PINS, WAIT GPIO, WAIT PIN, JMP PIN read them;
// MOV x, PINS reads output-only GPIOs as 0 without a fault; and the three
// fault kinds (drive an input pin, set direction on an output-only pin,
// read an output-only pin from a stalled WAIT): branch to FAULT_VEC that
// cycle, no write lands, bidirectional pads released and outputs at
// SAFE_OUT, fault_cause, later writes ignored, clr_fault recovers.
module tb_sm_gpio;
    localparam int W = 16;
    localparam logic [W-1:0] IN_ONLY  = 16'h000F;
    localparam logic [W-1:0] BIDIR    = 16'h0FF0;
    localparam logic [W-1:0] OUT_ONLY = 16'hF000;
    localparam logic [W-1:0] SAFE_OUT = 16'hA000;
    localparam logic [W-1:0] CAN_READ = IN_ONLY | BIDIR;
    localparam logic [4:0]   FV       = 5'd20;          // FAULT_VEC

    logic clk, rst, sm_rst, en, clr_fault;
    logic [31:0] clkdiv, execctrl, shiftctrl, pinctrl;

    // Instruction memory model: synchronous read, like the IHP SRAM.
    logic [15:0] imem [0:63];
    logic [15:0] instr;
    wire  [5:0]  mem_addr;
    wire         read_en;
    always @(posedge clk)
        if (read_en)
            instr <= imem[mem_addr];

    // GPIO controller, wired as in pio_spi_top
    wire [W-1:0] gpio_in, pins_re, pins_we, pins_wdata, dirs_we, dirs_wdata;
    wire         gpio_fault, fault;
    wire [2:0]   fault_cause;
    wire [W-1:0] pad_out, pad_oe;
    logic [W-1:0] ext_in;
    wire [W-1:0] pad_in = (pad_oe & pad_out) | (~pad_oe & ext_in);

    gpio_controller #(
        .DATA_WIDTH(W), .IN_ONLY(IN_ONLY), .BIDIR(BIDIR), .OUT_ONLY(OUT_ONLY), .SAFE_OUT(SAFE_OUT)
    ) u_gpio (
        .clk(clk), .rst(rst),
        .pins_we(pins_we), .pins_wdata(pins_wdata),
        .dirs_we(dirs_we), .dirs_wdata(dirs_wdata), .pins_re(pins_re),
        .gpio_in(gpio_in), .gpio_fault(gpio_fault),
        .clr_fault(clr_fault), .fault(fault), .fault_cause(fault_cause),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe)
    );

    wire [W-1:0] rx_data;
    wire         rx_push, tx_pop;
    wire [7:0]   irq_set, irq_clr;

    sm_no_smx_instr #(.DATA_WIDTH(W)) dut (
        .clk(clk), .external_rst(sm_rst), .imem_loaded(1'b1),
        .en(en), .restart(1'b0), .clkdiv_restart(1'b0),
        .mem_addr(mem_addr), .read_en(read_en), .instr(instr),
        .tx_data('0), .tx_empty(1'b1), .tx_level(3'd0), .tx_pop(tx_pop),
        .rx_data(rx_data), .rx_full(1'b0), .rx_level(3'd0), .rx_push(rx_push),
        .gpio_in(gpio_in), .pins_re(pins_re), .pins_we(pins_we), .pins_wdata(pins_wdata),
        .dirs_we(dirs_we), .dirs_wdata(dirs_wdata), .gpio_fault(gpio_fault),
        .irq_flags(8'd0), .irq_set(irq_set), .irq_clr(irq_clr)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_gpio);
    end

`ifdef SV_TEST
    `include "sm_tb_common.svh"

    initial clk = 0;
    always #5 clk = ~clk;

    int failures = 0;
    int cyc = 0;
    logic fault_expected;       // set by the fault tests

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
    // Monitors
    // ------------------------------------------------------------------------
    logic [W-1:0] exp_out, exp_oe;
    logic         mon_valid;

    // Before each edge, predict the controller's pin registers from the SM's
    // write masks; check them just after the edge.
    always @(posedge clk) begin
        cyc++;
        mon_valid = !rst && !clr_fault;
        if (gpio_fault || fault) begin
            exp_out = u_gpio.out_q;                 // nothing may land
            exp_oe  = u_gpio.oe_q;
        end else begin
            exp_out = (u_gpio.out_q & ~pins_we) | (pins_wdata & pins_we);
            exp_oe  = (u_gpio.oe_q  & ~dirs_we) | (dirs_wdata & dirs_we);
        end
        if (!rst && gpio_fault && !fault_expected)
            check(0, $sformatf("cycle %0d: unexpected GPIO fault at pc %0d (we %h, dirs %h, re %h)",
                               cyc, dut.pc, pins_we, dirs_we, pins_re));
    end

    always @(negedge clk) begin
        if (mon_valid) begin
            check(u_gpio.out_q === exp_out,
                  $sformatf("cycle %0d: pin levels %h, SM wrote %h", cyc, u_gpio.out_q, exp_out));
            check(u_gpio.oe_q === exp_oe,
                  $sformatf("cycle %0d: pin directions %h, SM wrote %h", cyc, u_gpio.oe_q, exp_oe));
        end
        if (!rst)
            check(gpio_in === (pad_in & CAN_READ),
                  $sformatf("cycle %0d: gpio_in %h, readable pads %h", cyc, gpio_in, pad_in & CAN_READ));
    end

    // ------------------------------------------------------------------------
    // Harness
    // ------------------------------------------------------------------------

    task automatic reset_all();
        rst = 1;
        sm_rst = 1;
        en = 0;
        clr_fault = 0;
        fault_expected = 0;
        ext_in = '0;
        for (int i = 0; i < 32; i++)
            imem[i] = i_jmp(C_ALWAYS, 5'(i));
        clkdiv    = clkdiv_f(1, 0);
        execctrl  = execctrl_f(0, 0, 0, FV, 31, 0, 0, 0);
        shiftctrl = shiftctrl_f(16, 16, 1, 1, 0, 0);
        pinctrl   = '0;
        step(2);
        rst = 0;
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

    task automatic start();
        boot();
        en = 1;
    endtask

    // ------------------------------------------------------------------------
    // Writes reach the pads
    // ------------------------------------------------------------------------

    // SET pindirs / pins, SET_BASE 4, SET_COUNT 5: GPIO 4-8.
    task automatic test_set();
        reset_all();
        pinctrl = pinctrl_f(0, 5, 0, 0, 0, 4, 0);
        imem[0] = i_set(S_PINDIRS, 5'b11111);
        imem[1] = i_set(S_PINS, 5'b10101);
        start();
        step(3);
        check(pad_oe[8:4] === 5'b11111, $sformatf("set: pad_oe[8:4]=%b", pad_oe[8:4]));
        check(pad_out[8:4] === 5'b10101, $sformatf("set: pad_out[8:4]=%b", pad_out[8:4]));
        check(pad_oe[3:0] === 4'b0 && pad_oe[11:9] === 3'b0, "set: other bidirectional pads driven");
    endtask

    // OUT pins and MOV pins, OUT_BASE 10, OUT_COUNT 4: GPIO 10-13 (10-11
    // bidirectional, made outputs first; 12-13 output only).
    task automatic test_out_mov();
        reset_all();
        pinctrl = pinctrl_f(0, 2, 4, 0, 0, 10, 10);
        imem[0] = i_set(S_PINDIRS, 5'b11);
        imem[1] = i_set(S_X, 5'b01001);
        imem[2] = i_mov(MD_OSR, MOP_NONE, MS_X);
        imem[3] = i_out(O_PINS, 4);                     // OSR[3:0] = 1001
        imem[4] = i_mov(MD_PINS, MOP_INV, MS_NULL);     // all ones
        start();
        step(4);
        check(pad_oe[11:10] === 2'b11, "out: GPIO 10-11 not outputs");
        check(pad_out[13:10] === 4'b1001, $sformatf("out pins: pad_out[13:10]=%b, expected 1001", pad_out[13:10]));
        step(1);
        check(pad_out[13:10] === 4'b1111, $sformatf("mov pins: pad_out[13:10]=%b, expected 1111", pad_out[13:10]));
        check(pad_out[15:14] === SAFE_OUT[15:14], "out/mov: GPIO 14-15 changed");
    endtask

    // Side-set to pins (SIDESET_BASE 12, 2 bits, mandatory) and to pindirs
    // (SIDESET_BASE 6, SIDE_PINDIR).
    task automatic test_sideset();
        reset_all();
        pinctrl = pinctrl_f(2, 0, 0, 0, 12, 0, 0);
        imem[0] = dss(NOP, 5'b10_000);                  // side 2: GPIO 13 = 1, 12 = 0
        imem[1] = dss(i_jmp(C_ALWAYS, 1), 5'b01_000);   // side 1: GPIO 12 = 1, 13 = 0
        start();
        step(1);
        check(pad_out[13:12] === 2'b10, $sformatf("side-set pins: pad_out[13:12]=%b, expected 10", pad_out[13:12]));
        step(2);
        check(pad_out[13:12] === 2'b01, $sformatf("side-set pins: pad_out[13:12]=%b, expected 01", pad_out[13:12]));

        reset_all();
        pinctrl  = pinctrl_f(2, 0, 0, 0, 6, 0, 0);
        execctrl = execctrl_f(0, 1, 0, FV, 31, 0, 0, 0);  // SIDE_PINDIR
        imem[0] = dss(i_jmp(C_ALWAYS, 0), 5'b11_000);
        start();
        step(2);
        check(pad_oe[7:6] === 2'b11, $sformatf("side-set pindirs: pad_oe[7:6]=%b, expected 11", pad_oe[7:6]));
    endtask

    // ------------------------------------------------------------------------
    // Reads see the pads
    // ------------------------------------------------------------------------

    // IN pins, IN_BASE 2: GPIO 2-5 (2-3 input only, 4-5 bidirectional inputs).
    task automatic test_in();
        reset_all();
        pinctrl = pinctrl_f(0, 0, 0, 2, 0, 0, 0);
        ext_in[5:2] = 4'b1011;
        imem[0] = i_in(IN_PINS, 4);
        imem[1] = i_mov(MD_X, MOP_NONE, MS_ISR);
        start();
        step(3);
        check(dut.x === 16'hB000, $sformatf("in pins: x=%h, expected b000", dut.x));
    endtask

    // WAIT 1 GPIO 3, and WAIT 1 PIN 1 with IN_BASE 2 (also GPIO 3).
    task automatic test_wait(input logic use_pin);
        string what = use_pin ? "wait pin" : "wait gpio";
        reset_all();
        pinctrl = pinctrl_f(0, 0, 0, 2, 0, 0, 0);
        imem[0] = use_pin ? i_wait(1, W_PIN, 1) : i_wait(1, W_GPIO, 3);
        imem[1] = i_set(S_X, 1);
        start();
        step(6);
        check(dut.pc === 6'd0 && dut.stall === 1'b1, {what, ": not waiting for GPIO 3"});
        check(pins_re === 16'h0008, $sformatf("%s: pins_re=%h, expected 0008", what, pins_re));
        ext_in[3] = 1;
        step(4);
        check(dut.x === 16'd1, {what, ": did not continue after GPIO 3 rose"});
    endtask

    // JMP PIN, JMP_PIN 9 (bidirectional input).
    task automatic test_jmp_pin(input logic level);
        reset_all();
        execctrl = execctrl_f(0, 0, 9, FV, 31, 0, 0, 0);
        ext_in[9] = level;
        imem[0] = i_jmp(C_PIN, 3);
        imem[1] = i_set(S_X, 1);
        imem[3] = i_set(S_X, 2);
        imem[4] = i_jmp(C_ALWAYS, 4);
        start();
        step(5);
        check(dut.x === (level ? 16'd2 : 16'd1), $sformatf("jmp pin, GPIO 9 = %b: x=%h", level, dut.x));
    endtask

    // MOV x, PINS reads every GPIO: output-only pads read 0, and no fault.
    task automatic test_mov_pins();
        reset_all();
        ext_in = '1;
        imem[0] = i_mov(MD_X, MOP_NONE, MS_PINS);
        start();
        step(3);
        check(pad_in[15:12] === SAFE_OUT[15:12], "mov pins: output pads not at SAFE_OUT");
        check(dut.x === 16'h0FFF, $sformatf("mov x, pins: x=%h, expected 0fff", dut.x));
        check(fault === 1'b0, "mov x, pins: raised a fault");
    endtask

    // ------------------------------------------------------------------------
    // Faults
    // ------------------------------------------------------------------------

    // Setup at 0-1 drives GPIO 4 high (bidirectional output). The faulting
    // instruction is at 2. The handler at FAULT_VEC (20) sets x = 30, then
    // keeps writing GPIO 4 low, which must be ignored until clr_fault.
    task automatic test_fault(input string what, input logic [15:0] bad,
                              input logic [31:0] pctrl, input logic [2:0] cause);
        logic [W-1:0] out_before, oe_before;
        reset_all();
        fault_expected = 1;
        pinctrl = pctrl;
        imem[0] = i_set(S_PINDIRS, 1);                  // SET_BASE 4
        imem[1] = i_set(S_PINS, 1);
        imem[2] = bad;
        imem[3] = i_jmp(C_ALWAYS, 3);
        imem[FV]     = i_set(S_X, 30);
        imem[FV + 1] = i_set(S_PINS, 0);
        imem[FV + 2] = i_jmp(C_ALWAYS, FV + 1);
        start();
        step(2);
        check(pad_oe[4] === 1'b1 && pad_out[4] === 1'b1, {what, ": setup did not drive GPIO 4 high"});
        check(dut.pc === 6'd2, $sformatf("%s: pc=%0d, expected 2", what, dut.pc));
        check(gpio_fault === 1'b1, {what, ": no gpio_fault on the bad access"});
        out_before = u_gpio.out_q;
        oe_before  = u_gpio.oe_q;

        step(1);                                        // the fault edge
        check(dut.pc === 6'(FV), $sformatf("%s: pc=%0d after the fault, expected FAULT_VEC %0d", what, dut.pc, FV));
        check(u_gpio.out_q === out_before && u_gpio.oe_q === oe_before, {what, ": a write landed on the fault cycle"});
        check(fault === 1'b1, {what, ": sticky fault not set"});
        check(fault_cause === cause, $sformatf("%s: fault_cause=%b, expected %b", what, fault_cause, cause));
        check(pad_oe === OUT_ONLY, $sformatf("%s: pad_oe=%h, expected only outputs (%h)", what, pad_oe, OUT_ONLY));
        check(pad_out === SAFE_OUT, $sformatf("%s: pad_out=%h, expected SAFE_OUT", what, pad_out));

        step(5);
        check(dut.x === 16'd30, {what, ": fault handler did not run"});
        check(u_gpio.out_q[4] === 1'b1, {what, ": handler write landed while faulted"});
        check(fault === 1'b1, {what, ": fault cleared without clr_fault"});

        clr_fault = 1;
        step(1);
        clr_fault = 0;
        check(fault === 1'b0 && fault_cause === 3'b000, {what, ": clr_fault did not clear the fault"});
        step(3);
        check(u_gpio.out_q[4] === 1'b0, {what, ": handler write ignored after clr_fault"});
    endtask

    initial begin
        test_set();
        test_out_mov();
        test_sideset();
        test_in();
        test_wait(0);
        test_wait(1);
        test_jmp_pin(1);
        test_jmp_pin(0);
        test_mov_pins();
        // Drive an input-only pin: MOV pins with OUT_BASE 2.
        test_fault("drive input pin", i_mov(MD_PINS, MOP_INV, MS_NULL),
                   pinctrl_f(0, 1, 1, 0, 0, 4, 2), 3'b001);
        // Set the direction of an output-only pin: OUT pindirs with OUT_BASE 13.
        test_fault("dir on output pin", i_out(O_PINDIRS, 1),
                   pinctrl_f(0, 1, 1, 0, 0, 4, 13), 3'b010);
        // Read an output-only pin from a stalled WAIT: the fault wins.
        test_fault("read output pin", i_wait(1, W_GPIO, 14),
                   pinctrl_f(0, 1, 1, 0, 0, 4, 0), 3'b100);

        if (failures == 0) begin
            $display("SM <-> GPIO controller integration test passed");
            $finish;
        end else
            $fatal(1, "SM <-> GPIO controller integration test: %0d check(s) failed", failures);
    end

    initial begin
        #2ms;
        $fatal(1, "timeout");
    end
`endif
endmodule
