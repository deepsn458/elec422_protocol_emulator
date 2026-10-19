// isr - Input Shift Register for one PIO state machine
//
//   * IN shifts n bits (n = 0 means 32) of a right-aligned source into q:
//     dir = 1 (shift right): new bits enter at the MSB end.
//     dir = 0 (shift left) : new bits enter at the LSB end.
//   * cnt counts the bits shifted in and saturates at 32.
//   * load replaces q and cnt (PUSH: din = 0, load_cnt = 0;
//     OUT ISR: load_cnt = bit count; MOV ISR: load_cnt = 0).
//   * shift_q / shift_cnt are the values a shift would produce this cycle,
//     used by the execute logic to autopush in the same instruction.
//
// Priority: load > shift. Nothing changes unless ce is high.

`default_nettype none

module isr (
  input  logic        clk,
  input  logic        rst,        // synchronous, active high (rst | sm restart)
  input  logic        ce,         // tick & ~stall
  input  logic        load,
  input  logic [5:0]  load_cnt,   // 0..32 (larger values clamp to 32)
  input  logic        shift,
  input  logic [4:0]  n,          // bit count, 0 = 32
  input  logic        dir,        // 1 = shift right, 0 = shift left
  input  logic [31:0] din,        // load value, or right-aligned shift source
  output logic [31:0] q,
  output logic [5:0]  cnt,
  output logic [31:0] shift_q,    // value of q after a shift
  output logic [5:0]  shift_cnt   // value of cnt after a shift
);

  localparam logic [5:0] FULL = 6'd32;

  logic [5:0]  n_eff;     // 1..32
  logic [31:0] mask;      // low n_eff bits set
  logic [31:0] src;       // din with only the low n_eff bits kept
  logic [6:0]  cnt_sum;   // cnt + n_eff before saturation (up to 64)

  // 0 encodes 32
  assign n_eff = (n == 5'd0) ? FULL : {1'b0, n};

  // lowmask(32) = all ones
  assign mask  = (n_eff == FULL) ? 32'hFFFF_FFFF : ((32'h1 << n_eff) - 32'h1);
  assign src   = din & mask;

  // Right: old bits move down by n, src[n-1:0] enters at the MSB end.
  // Left : old bits move up by n,   src[n-1:0] enters at the LSB end.
  // A 32-bit shift by 32 yields 0, so n = 32 gives shift_q = src.
  assign shift_q = dir ? ((q >> n_eff) | (src << (FULL - n_eff)))
                       : ((q << n_eff) | src);

  assign cnt_sum   = {1'b0, cnt} + {1'b0, n_eff};
  assign shift_cnt = (cnt_sum > 7'(FULL)) ? FULL : cnt_sum[5:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      q   <= '0;
      cnt <= '0;                                   // empty
    end else if (ce) begin
      if (load) begin
        q   <= din;
        cnt <= (load_cnt > FULL) ? FULL : load_cnt;
      end else if (shift) begin
        q   <= shift_q;
        cnt <= shift_cnt;
      end
    end
  end

endmodule

`default_nettype wire
