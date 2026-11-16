// gpio_controller - pin registers and run-time pin access checks for one SM
//
// The SM addresses DATA_WIDTH logical GPIOs. Each logical GPIO is one pad
// type, fixed at design time by three disjoint masks:
//   IN_ONLY   can be read; cannot be driven or change direction
//   BIDIR     can be read, driven, and switched between input and output
//   OUT_ONLY  always driven; cannot be read or change direction
// A GPIO in none of the masks supports nothing.
//
// Run-time check (every cycle, combinational): a fault is raised when this
// cycle's access touches a GPIO that cannot do it:
//   drive: pins_we on a GPIO that is not BIDIR or OUT_ONLY
//   dir:   dirs_we on a GPIO that is not BIDIR
//   read:  pins_re on a GPIO that is not BIDIR or IN_ONLY
// gpio_fault goes straight back to the SM, which branches to FAULT_VEC that
// cycle. It is per-cycle, not sticky, so the SM can run the handler.
//
// On a fault:
//   * none of the faulting cycle's writes reach the registers;
//   * from the next cycle the sticky 'fault' flag releases every BIDIR pad
//     (pad_oe = 0) and holds every OUT_ONLY pad at SAFE_OUT, and further SM
//     writes are ignored. The pads only ever change on a clock edge, so they
//     never glitch on the combinational fault.
//   * fault_cause records which checks failed ({read, dir, drive}).
// Only rst or clr_fault (host, one-cycle pulse) clears the fault; both also
// return the pin registers to their reset state (outputs SAFE_OUT, all BIDIR
// pins inputs) so no stale level reappears on the pads.
//
// Reads: gpio_in to the SM is pad_in for readable GPIOs and 0 elsewhere.
// pad_out / pad_oe / pad_in are in logical GPIO order; the top level wires
// them to the Tiny Tapeout ui_in / uo_out / uio_* pins. pad_oe is always 1
// for OUT_ONLY GPIOs (uo_out has no enable).
//
// Default mapping (gpio_controller.md): GPIO 0 input, 1-8 bidirectional,
// 9-15 output.

`default_nettype none

module gpio_controller #(
  parameter int DATA_WIDTH = 16,
  parameter logic [DATA_WIDTH-1:0] IN_ONLY  = 16'h0001,
  parameter logic [DATA_WIDTH-1:0] BIDIR    = 16'h01FE,
  parameter logic [DATA_WIDTH-1:0] OUT_ONLY = 16'hFE00,
  // Level for output pins at reset and while faulted (e.g. 1 for a UART TX
  // or an active-low chip select).
  parameter logic [DATA_WIDTH-1:0] SAFE_OUT = '0
) (
  input  logic                  clk,
  input  logic                  rst,          // synchronous, active high

  // State machine side
  input  logic [DATA_WIDTH-1:0] pins_we,
  input  logic [DATA_WIDTH-1:0] pins_wdata,
  input  logic [DATA_WIDTH-1:0] dirs_we,
  input  logic [DATA_WIDTH-1:0] dirs_wdata,  // 1 = output, 0 = input
  input  logic [DATA_WIDTH-1:0] pins_re,
  output logic [DATA_WIDTH-1:0] gpio_in,
  output logic                  gpio_fault,   // per-cycle, to the SM

  // Host side
  input  logic                  clr_fault,    // one-cycle pulse
  output logic                  fault,        // sticky
  output logic [2:0]            fault_cause,  // sticky {read, dir, drive}

  // Pads, logical GPIO order
  input  logic [DATA_WIDTH-1:0] pad_in,
  output logic [DATA_WIDTH-1:0] pad_out,
  output logic [DATA_WIDTH-1:0] pad_oe
);

  localparam logic [DATA_WIDTH-1:0] CAN_DRIVE = BIDIR | OUT_ONLY;
  localparam logic [DATA_WIDTH-1:0] CAN_DIR   = BIDIR;
  localparam logic [DATA_WIDTH-1:0] CAN_READ  = BIDIR | IN_ONLY;

`ifndef SYNTHESIS
  initial begin
    if ((IN_ONLY & BIDIR) != '0 || (IN_ONLY & OUT_ONLY) != '0 || (BIDIR & OUT_ONLY) != '0)
      $fatal(1, "gpio_controller: IN_ONLY, BIDIR and OUT_ONLY must not overlap");
  end
`endif

  // ---------------------------------------------------------------------------
  // Run-time check
  // ---------------------------------------------------------------------------

  logic bad_drive, bad_dir, bad_read;

  assign bad_drive  = |(pins_we & ~CAN_DRIVE);
  assign bad_dir    = |(dirs_we & ~CAN_DIR);
  assign bad_read   = |(pins_re & ~CAN_READ);
  assign gpio_fault = bad_drive | bad_dir | bad_read;

  // ---------------------------------------------------------------------------
  // Pin registers and fault flag
  // ---------------------------------------------------------------------------

  logic [DATA_WIDTH-1:0] out_q, oe_q;

  always_ff @(posedge clk) begin
    if (rst || clr_fault) begin
      out_q       <= SAFE_OUT;
      oe_q        <= '0;
      fault       <= 1'b0;
      fault_cause <= 3'b000;
    end else begin
      // With no fault, every write targets a GPIO that supports it.
      if (!gpio_fault && !fault) begin
        out_q <= (out_q & ~pins_we) | (pins_wdata & pins_we);
        oe_q  <= (oe_q  & ~dirs_we) | (dirs_wdata & dirs_we);
      end
      if (gpio_fault) begin
        fault       <= 1'b1;
        fault_cause <= fault_cause | {bad_read, bad_dir, bad_drive};
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pads
  // ---------------------------------------------------------------------------

  assign pad_oe  = (fault ? '0 : (oe_q & BIDIR)) | OUT_ONLY;
  assign pad_out = fault ? SAFE_OUT : out_q;
  assign gpio_in = pad_in & CAN_READ;

endmodule

`default_nettype wire
