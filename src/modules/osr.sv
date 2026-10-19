// osr - Output Shift Register for one PIO state machine
//
//   * OUT removes n bits (n = 0 means 32) from q:
//     dir = 1 (shift right, LSB first): the low n bits leave.
//     dir = 0 (shift left,  MSB first): the high n bits leave.
//     The bits that leave appear right-aligned on 'shifted'; q keeps the
//     rest, zero filled.
//   * q is always the full register (for MOV x, osr / IN osr).
//   * cnt counts bits shifted out: 0 = full, 32 = empty, saturates at 32.
//     Reset value 32, so the first OUT with autopull triggers a refill.
//   * load (PULL, autopull, MOV OSR) sets q = din and cnt = 0.
//   * shift_cnt is the count a shift would produce this cycle.
//
// Priority: load > shift. Nothing changes unless ce is high.

`default_nettype none

module osr (
  input  logic        clk,
  input  logic        rst,        // synchronous, active high (rst | sm restart)
  input  logic        ce,         // tick & ~stall
  input  logic        load,
  input  logic        shift,
  input  logic [4:0]  n,          // bit count, 0 = 32
  input  logic        dir,        // 1 = shift right (LSB first), 0 = left (MSB first)
  input  logic [31:0] din,
  output logic [31:0] q,
  output logic [31:0] shifted,    // right-aligned bits shifted out
  output logic [5:0]  cnt,
  output logic [5:0]  shift_cnt
);

  localparam logic [5:0] FULL = 6'd32;

  logic [5:0]  n_eff;     // 1..32
  logic [63:0] cat_r;     // {q, 0} >> n
  logic [63:0] cat_l;     // {0, q} << n
  logic [5:0]  back;      // 32 - n, 0..31
  logic [31:0] rest;      // q after the shift
  logic [6:0]  cnt_sum;   // cnt + n_eff before saturation (up to 64)

  assign n_eff = (n == 5'd0) ? FULL : {1'b0, n};

  // Right: {q, 0} >> n. High word = remaining bits, low word = bits that
  //        fell out, left-aligned at [31:32-n]; shift them back by 32-n.
  // Left : {0, q} << n. High word = bits shifted out (already
  //        right-aligned), low word = remaining bits.
  assign cat_r = {q, 32'd0} >> n_eff;
  assign cat_l = {32'd0, q} << n_eff;
  assign back  = FULL - n_eff;

  assign shifted = dir ? (cat_r[31:0] >> back) : cat_l[63:32];
  assign rest    = dir ? cat_r[63:32]          : cat_l[31:0];

  assign cnt_sum   = {1'b0, cnt} + {1'b0, n_eff};
  assign shift_cnt = (cnt_sum > 7'(FULL)) ? FULL : cnt_sum[5:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      q   <= '0;
      cnt <= FULL;                                 // empty
    end else if (ce) begin
      if (load) begin
        q   <= din;
        cnt <= '0;                                 // full
      end else if (shift) begin
        q   <= rest;
        cnt <= shift_cnt;
      end
    end
  end

endmodule

`default_nettype wire
