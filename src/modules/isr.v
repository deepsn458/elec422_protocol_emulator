module isr (
  input  wire        clk,
  input  wire        rst,
  input  wire        ce,
  input  wire        load,
  input  wire [5:0]  load_cnt,  // 0..32
  input  wire        shift,
  input  wire [4:0]  n,         // bit count, 0 = 32
  input  wire        dir,       // 1 = shift right, 0 = shift left
  input  wire [31:0] din,       // load value, or right-aligned shift source
  output reg  [31:0] q,
  output reg  [5:0]  cnt,
  output wire [31:0] shift_q,   // value of q after a shift
  output wire [5:0]  shift_cnt  // value of cnt after a shift
);

  // 0 encodes 32
  wire [5:0] n_eff = (n == 5'd0) ? 6'd32 : {1'b0, n};

  // Keep only the low n_eff bits of the source. lowmask(32) = all ones.
  wire [31:0] mask   = (n_eff == 6'd32) ? 32'hFFFF_FFFF : ((32'h1 << n_eff) - 32'h1);
  wire [31:0] src    = din & mask;

  // Right: old bits move down by n, src[n-1:0] enters at the MSB end.
  // Left : old bits move up by n,   src[n-1:0] enters at the LSB end.
  // A 32-bit shift by 32 yields 0 in Verilog, so n = 32 gives q = src.
  wire [31:0] shl_r  = (q >> n_eff) | (src << (6'd32 - n_eff));
  wire [31:0] shl_l  = (q << n_eff) | src;

  assign shift_q   = dir ? shl_r : shl_l;

  wire [6:0] cnt_sum = {1'b0, cnt} + {1'b0, n_eff};
  assign shift_cnt   = (cnt_sum > 7'd32) ? 6'd32 : cnt_sum[5:0];

  always @(posedge clk) begin
    if (rst) begin
      q   <= 32'd0;
      cnt <= 6'd0;               // empty
    end else if (ce) begin
      if (load) begin
        q   <= din;
        cnt <= (load_cnt > 6'd32) ? 6'd32 : load_cnt;
      end else if (shift) begin
        q   <= shift_q;
        cnt <= shift_cnt;
      end
    end
  end

endmodule