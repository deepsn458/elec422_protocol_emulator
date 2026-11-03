// clockdiv - fractional clock divider for one PIO state machine
//
//   * Produces a one-cycle clock enable, tick, at an average rate of
//     clk / (div_int + div_frac / 256). The state machine runs only on
//     cycles where tick is high; the clock itself is never divided.
//   * div_int = 0 means 65536. div_int = 1, div_frac = 0 ticks every cycle.
//   * ctr counts down the cycles left in the current period (1 = last).
//     On a tick it reloads with div_int, plus one when the fractional
//     accumulator acc wraps past 256 (first-order delta-sigma), so a
//     divisor of 2.5 gives periods of 2, 3, 2, 3, ...
//   * rst (reset or CTRL.CLKDIV_RESTART) restarts at phase 0: tick is
//     high on the first cycle after rst falls.
//
// The divider is free running; SM enable does not stop it.

`default_nettype none

module clockdiv (
  input  logic        clk,
  input  logic        rst,        // synchronous, active high (rst | clkdiv restart)
  input  logic [15:0] div_int,    // CLKDIV.INT, 0 = 65536
  input  logic [7:0]  div_frac,   // CLKDIV.FRAC, in 1/256 steps
  output logic        tick
);

  logic [16:0] ctr;       // cycles left in this period, 1..65537
  logic [7:0]  acc;       // fractional phase
  logic [8:0]  acc_sum;   // acc + div_frac, bit 8 = carry
  logic [16:0] period;    // length of the next period

  assign acc_sum = {1'b0, acc} + {1'b0, div_frac};
  assign period  = ((div_int == 16'd0) ? 17'h1_0000 : {1'b0, div_int})
                 + {16'd0, acc_sum[8]};
  assign tick    = (ctr == 17'd1);

  always_ff @(posedge clk) begin
    if (rst) begin
      ctr <= 17'd1;
      acc <= '0;
    end else if (tick) begin
      ctr <= period;
      acc <= acc_sum[7:0];
    end else begin
      ctr <= ctr - 17'd1;
    end
  end

endmodule

`default_nettype wire
