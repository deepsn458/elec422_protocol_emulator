`default_nettype none
`timescale 1ns / 1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb.fst"
`endif

/* The DUT wiring is shared by cocotb and the optional SystemVerilog test.
   With FLOW=sv, the Makefile defines SV_TEST to enable the stimulus below. */
module tb ();

  // Dump the signals to a FST file. You can view it with gtkwave or surfer.
  initial begin
    $dumpfile(`TB_DUMPFILE);
    $dumpvars(0, tb);
    #1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // Replace tt_um_example with your module name:
  tt_um_example user_project (
      .ui_in  (ui_in),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

`ifdef SV_TEST
  // Replace or extend this example with checks for your design.
  // The 10 us period matches the cocotb example in test.py.
  initial clk = 0;
  always #5000 clk = ~clk;

  initial begin
    ena = 1;
    ui_in = 0;
    uio_in = 0;
    rst_n = 0;

    repeat (10) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    ui_in = 20;
    uio_in = 30;
    @(posedge clk);
    #1;
    if (uo_out !== 8'd50)
      $fatal(1, "uo_out: expected 50, got %0d", uo_out);

    $display("SystemVerilog test passed");
    $finish;
  end
`endif

endmodule
