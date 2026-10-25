// osr - Output Shift Register for one PIO state machine
//
//   * OUT removes n bits (n = 0 means DATA_WIDTH) from q:
//     dir = 1 (shift right, LSB first): the low n bits leave.
//     dir = 0 (shift left,  MSB first): the high n bits leave.
//     The bits that leave appear right-aligned on 'shifted'; q keeps the
//     rest, zero filled.
//   * q is always the full register (for MOV x, osr / IN osr).
//   * cnt counts bits shifted out: 0 = full, DATA_WIDTH = empty,
//     saturates at DATA_WIDTH. Reset value DATA_WIDTH, so the first OUT
//     with autopull triggers a refill.
//   * load (PULL, autopull, MOV OSR) sets q = din and cnt = 0.
//   * shift_cnt is the count a shift would produce this cycle.
//
// Priority: load > shift. Nothing changes unless ce is high.

`default_nettype none

module osr #(
  parameter DATA_WIDTH = 8,
  parameter DW_BITS = $clog2(DATA_WIDTH)
)(
  input  logic        clk,
  input  logic        rst,        // synchronous, active high (rst | sm restart)
  input  logic        ce,         // tick & ~stall
  input  logic        load,
  input  logic        shift,
  input  logic [DW_BITS-1:0] n,   // bit count, 0 = DATA_WIDTH
  input  logic        dir,        // 1 = shift right (LSB first), 0 = left (MSB first)
  input  logic [DATA_WIDTH-1:0] din,
  output logic [DATA_WIDTH-1:0] q,
  output logic [DATA_WIDTH-1:0] shifted,    // right-aligned bits shifted out
  output logic [DW_BITS:0] cnt,
  output logic [DW_BITS:0] shift_cnt
);

  localparam logic [DW_BITS:0] FULL = DATA_WIDTH;

  logic [DW_BITS:0] n_eff;                  // 1..DATA_WIDTH
  logic [2*DATA_WIDTH-1:0] cat_r;          // {q, 0} >> n
  logic [2*DATA_WIDTH-1:0] cat_l;          // {0, q} << n
  logic [DW_BITS:0] back;                   // DATA_WIDTH - n
  logic [DATA_WIDTH-1:0] rest;             // q after the shift
  logic [DW_BITS+1:0] cnt_sum;             // cnt + n_eff before saturation

  assign n_eff = (n == '0) ? FULL : {1'b0, n};

  // Right: {q, 0} >> n. High word = remaining bits, low word = bits that
  //        fell out, left-aligned at [DATA_WIDTH-1:DATA_WIDTH-n];
  //        shift them back by DATA_WIDTH-n.
  // Left : {0, q} << n. High word = bits shifted out (already
  //        right-aligned), low word = remaining bits.
  assign cat_r = {q, {DATA_WIDTH{1'b0}}} >> n_eff;
  assign cat_l = {{DATA_WIDTH{1'b0}}, q} << n_eff;
  assign back  = FULL - n_eff;

  assign shifted = dir ? (cat_r[DATA_WIDTH-1:0] >> back)
                       : cat_l[2*DATA_WIDTH-1:DATA_WIDTH];
  assign rest    = dir ? cat_r[2*DATA_WIDTH-1:DATA_WIDTH]
                       : cat_l[DATA_WIDTH-1:0];

  assign cnt_sum   = {1'b0, cnt} + {1'b0, n_eff};
  assign shift_cnt = (cnt_sum > {1'b0, FULL}) ? FULL : cnt_sum[DW_BITS:0];

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
