// isr - Input Shift Register for one PIO state machine
//
//   * IN shifts n bits (n = 0 means DATA_WIDTH) of a right-aligned source into q:
//     dir = 1 (shift right): new bits enter at the MSB end.
//     dir = 0 (shift left) : new bits enter at the LSB end.
//   * cnt counts the bits shifted in and saturates at DATA_WIDTH.
//   * load replaces q and cnt (PUSH: din = 0, load_cnt = 0;
//     OUT ISR: load_cnt = bit count; MOV ISR: load_cnt = 0).
//   * shift_q / shift_cnt are the values a shift would produce this cycle,
//     used by the execute logic to autopush in the same instruction.
//
// Priority: load > shift. Nothing changes unless ce is high.

`default_nettype none

module isr #(
    parameter DATA_WIDTH = 8,
    parameter DW_BITS = $clog2(DATA_WIDTH)
    )(
  input  logic        clk,
  input  logic        rst,        // synchronous, active high (rst | sm restart)
  input  logic        ce,         // tick & ~stall
  input  logic        load,
  input  logic [DW_BITS:0]  load_cnt,   // 0..DATA_WIDTH (larger values clamp to DATA_WIDTH)
  input  logic        shift,
  input  logic [DW_BITS-1:0]  n,          // bit count, 0 = DATA_WIDTH
  input  logic        dir,        // 1 = shift right, 0 = shift left
  input  logic [DATA_WIDTH-1:0] din,        // load value, or right-aligned shift source
  output logic [DATA_WIDTH-1:0] q,
  output logic [DW_BITS:0]  cnt,
  output logic [DATA_WIDTH-1:0] shift_q,    // value of q after a shift
  output logic [DW_BITS:0]  shift_cnt   // value of cnt after a shift
);

  localparam logic [DW_BITS:0] FULL = DATA_WIDTH;

  logic [DW_BITS:0] n_eff;                 // 1..DATA_WIDTH
  logic [DATA_WIDTH-1:0] mask;            // low n_eff bits set
  logic [DATA_WIDTH-1:0] src;             // din with only the low n_eff bits kept
  logic [DW_BITS+1:0] cnt_sum;            // cnt + n_eff before saturation

  // 0 encodes DATA_WIDTH
  assign n_eff = (n == '0) ? FULL : {1'b0, n};

  // lowmask(DATA_WIDTH) = all ones
  // used to shift lower n bits in
  assign mask  = (DATA_WIDTH'(1) << n_eff) - DATA_WIDTH'(1);
  assign src   = din & mask;

  // Right: old bits move down by n, src[n-1:0] enters at the MSB end.
  // Left : old bits move up by n,   src[n-1:0] enters at the LSB end.
  // A DATA_WIDTH-bit shift by DATA_WIDTH yields 0, so n = 0 gives shift_q = src.
  assign shift_q = dir ? ((q >> n_eff) | (src << (FULL - n_eff)))
                       : ((q << n_eff) | src);

  assign cnt_sum   = {1'b0, cnt} + {1'b0, n_eff};
  assign shift_cnt = (cnt_sum > {1'b0, FULL}) ? FULL : cnt_sum[DW_BITS:0];

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
