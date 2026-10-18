module osr (
  input  wire        clk,
  input  wire        rst,
  input  wire        ce,
  input  wire        load,
  input  wire        shift,
  input  wire [4:0]  n,         // bit count, 0 = 32
  input  wire        dir,       // 1 = shift right (LSB first), 0 = left (MSB first)
  input  wire [31:0] din,
  output reg  [31:0] q,
  output wire [31:0] shifted,   // right-aligned bits shifted out
  output reg  [5:0]  cnt,
  output wire [5:0]  shift_cnt
);

  wire [5:0] n_eff = (n == 5'd0) ? 6'd32 : {1'b0, n};

  // Right: {q, 0} >> n. High word = remaining bits, low word = bits that fell
  //        out, left-aligned at [31:32-n]; shift them back down by 32-n.
  // Left : {0, q} << n. High word = bits shifted out (already right-aligned),
  //        low word = remaining bits.
  wire [63:0] cat_r = {q, 32'd0} >> n_eff;
  wire [63:0] cat_l = {32'd0, q} << n_eff;

  wire [5:0]  back  = 6'd32 - n_eff;             // 0..31
  assign shifted    = dir ? (cat_r[31:0] >> back) : cat_l[63:32];
  wire [31:0] rest  = dir ? cat_r[63:32]          : cat_l[31:0];

  wire [6:0] cnt_sum = {1'b0, cnt} + {1'b0, n_eff};
  assign shift_cnt   = (cnt_sum > 7'd32) ? 6'd32 : cnt_sum[5:0];

  always @(posedge clk) begin
    if (rst) begin
      q   <= 32'd0;
      cnt <= 6'd32;              // empty
    end else if (ce) begin
      if (load) begin
        q   <= din;
        cnt <= 6'd0;             // full
      end else if (shift) begin
        q   <= rest;
        cnt <= shift_cnt;
      end
    end
  end

endmodule