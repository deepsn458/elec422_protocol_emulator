`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_gpio_controller.fst"
`endif

module tb_gpio_controller;
    localparam int W = 16;
    // Default mapping: GPIO 0-3 input, 4-11 bidirectional, 12-15 output.
    localparam [W-1:0] IN_ONLY  = 16'h000F;
    localparam [W-1:0] BIDIR    = 16'h0FF0;
    localparam [W-1:0] OUT_ONLY = 16'hF000;
    localparam [W-1:0] SAFE2    = 16'hA000;   // second instance: GPIO 13, 15 idle high

    reg clk;
    reg rst;
    reg [W-1:0] pins_we, pins_wdata, dirs_we, dirs_wdata, pins_re;
    reg clr_fault;
    reg [W-1:0] pad_in;

    wire [W-1:0] gpio_in, pad_out, pad_oe;
    wire gpio_fault, fault;
    wire [2:0] fault_cause;

    gpio_controller #(.DATA_WIDTH(W)) dut (
        .clk(clk),
        .rst(rst),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .pins_re(pins_re),
        .gpio_in(gpio_in),
        .gpio_fault(gpio_fault),
        .clr_fault(clr_fault),
        .fault(fault),
        .fault_cause(fault_cause),
        .pad_in(pad_in),
        .pad_out(pad_out),
        .pad_oe(pad_oe)
    );

    // Same inputs, non-zero SAFE_OUT.
    wire [W-1:0] gpio_in2, pad_out2, pad_oe2;
    wire gpio_fault2, fault2;
    wire [2:0] fault_cause2;

    gpio_controller #(.DATA_WIDTH(W), .SAFE_OUT(SAFE2)) dut2 (
        .clk(clk),
        .rst(rst),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .pins_re(pins_re),
        .gpio_in(gpio_in2),
        .gpio_fault(gpio_fault2),
        .clr_fault(clr_fault),
        .fault(fault2),
        .fault_cause(fault_cause2),
        .pad_in(pad_in),
        .pad_out(pad_out2),
        .pad_oe(pad_oe2)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_gpio_controller);
    end

`ifdef SV_TEST
    initial clk = 0;
    always #5 clk = ~clk;

    // Inputs change and results are checked 1 ns after the rising edge.
    task automatic step(input int n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check(input [31:0] got, input [31:0] exp, input string what);
        if (got !== exp)
            $error("%s: got %h, expected %h", what, got, exp);
    endtask

    task automatic idle();
        pins_we = 0;
        pins_wdata = 0;
        dirs_we = 0;
        dirs_wdata = 0;
        pins_re = 0;
        clr_fault = 0;
    endtask

    // One SM cycle of accesses; checks gpio_fault before the clock edge.
    task automatic access(input [W-1:0] pwe, input [W-1:0] pwd,
                          input [W-1:0] dwe, input [W-1:0] dwd,
                          input [W-1:0] re, input exp_fault, input string what);
        pins_we = pwe;
        pins_wdata = pwd;
        dirs_we = dwe;
        dirs_wdata = dwd;
        pins_re = re;
        #1;
        check(gpio_fault, exp_fault, {what, ": gpio_fault"});
        step(1);
        idle();
    endtask

    task automatic clear();
        clr_fault = 1;
        step(1);
        clr_fault = 0;
        check(fault, 0, "clear: fault");
        check(fault_cause, 0, "clear: cause");
        check(pad_oe, OUT_ONLY, "clear: bidir pins are inputs");
        check(pad_out, 0, "clear: outputs at SAFE_OUT");
    endtask

    initial begin
        rst = 1;
        idle();
        pad_in = 0;
        step(2);
        rst = 0;

        // Reset: output-only pads driven at SAFE_OUT, bidir pads released.
        check(pad_oe, OUT_ONLY, "reset: pad_oe");
        check(pad_out, 0, "reset: pad_out");
        check(pad_out2, SAFE2, "reset: pad_out (SAFE_OUT)");
        check(fault, 0, "reset: fault");
        check(gpio_fault, 0, "reset: no gpio_fault");

        // Reads: only input and bidir pins reach the SM.
        pad_in = 16'hFFFF;
        #1;
        check(gpio_in, IN_ONLY | BIDIR, "gpio_in masks output-only pins");
        pad_in = 16'h5A5A;
        #1;
        check(gpio_in, 16'h5A5A & 16'h0FFF, "gpio_in passes readable pins");

        // Valid accesses: set pindirs on GPIO 5, drive GPIO 5 and 13, read 0-11.
        access(0, 0, 16'h0020, 16'h0020, 0, 0, "set pindirs gpio 5");
        check(pad_oe, OUT_ONLY | 16'h0020, "gpio 5 is an output");
        access(16'h2020, 16'h2020, 0, 0, 0, 0, "set pins gpio 5, 13");
        check(pad_out, 16'h2020, "gpio 5, 13 driven high");
        access(0, 0, 0, 0, 16'h0FFF, 0, "read gpio 0-11");
        access(16'h2000, 0, 0, 0, 0, 0, "clear gpio 13");
        check(pad_out, 16'h0020, "gpio 13 low");
        // Side-set style: pins and dirs in the same cycle.
        access(16'h0040, 16'h0040, 16'h0040, 16'h0040, 0, 0, "pins + dirs gpio 6");
        check(pad_oe, OUT_ONLY | 16'h0060, "gpio 6 is an output");
        check(pad_out, 16'h0060, "gpio 6 high");
        check(fault, 0, "no fault after valid accesses");

        // Dir write on an output-only pin (I2C SDA on GPIO 13). The valid
        // write to GPIO 5 in the same cycle must not land either.
        access(16'h0020, 0, 16'h2000, 0, 0, 1, "pindirs on output-only gpio 13");
        check(fault, 1, "dir fault: sticky fault");
        check(fault_cause, 3'b010, "dir fault: cause");
        check(dut.out_q, 16'h0060, "dir fault: faulting cycle's writes dropped");
        check(pad_oe, OUT_ONLY, "dir fault: bidir pads released");
        check(pad_out, 0, "dir fault: outputs at SAFE_OUT");
        check(pad_out2, SAFE2, "dir fault: outputs at SAFE_OUT (instance 2)");
        // While faulted, valid writes are ignored and the pads stay safe.
        access(16'h1000, 16'h1000, 16'h0010, 16'h0010, 0, 0, "valid write while faulted");
        check(dut.out_q, 16'h0060, "faulted: registers frozen");
        check(pad_oe, OUT_ONLY, "faulted: pad_oe");
        check(pad_out, 0, "faulted: pad_out");
        step(3);
        check(fault, 1, "fault stays set");
        clear();
        check(dut.out_q, 0, "clear: out register reset");
        check(dut.oe_q, 0, "clear: oe register reset");
        check(pad_out2, SAFE2, "clear: outputs at SAFE_OUT (instance 2)");

        // Drive on the input-only pin.
        access(16'h0001, 16'h0001, 0, 0, 0, 1, "drive input-only gpio 0");
        check(fault_cause, 3'b001, "drive fault: cause");
        clear();

        // Read of an output-only pin (e.g. JMP PIN on GPIO 14).
        access(0, 0, 0, 0, 16'h4000, 1, "read output-only gpio 14");
        check(fault_cause, 3'b100, "read fault: cause");
        // A second, different fault accumulates causes.
        access(0, 0, 16'h0001, 16'h0001, 0, 1, "pindirs on input-only gpio 0");
        check(fault_cause, 3'b110, "causes accumulate");
        clear();

        // A range that wraps (OUT_BASE 14, OUT_COUNT 4 -> GPIO 14, 15, 0, 1):
        // GPIO 0 is input-only, so the whole write faults.
        access(16'hC003, 16'hFFFF, 0, 0, 0, 1, "wrapping out range");
        check(fault_cause, 3'b001, "wrap: drive cause");
        check(pad_out, 0, "wrap: nothing driven");
        clear();

        // rst also clears the fault.
        access(0, 0, 16'h8000, 16'h8000, 0, 1, "pindirs on output-only gpio 15");
        rst = 1;
        step(1);
        rst = 0;
        check(fault, 0, "rst clears fault");
        check(pad_oe, OUT_ONLY, "rst: pad_oe");

        $display("GPIO_CONTROLLER SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
