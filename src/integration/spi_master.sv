// spi_master - SPI controller (master) with settable CPOL / CPHA, for tests
//
// Test-only model: it is used by integration testbenches to drive spi_slave
// and is not part of the synthesized design.
//
//   * Transfers are DATA_WIDTH bits (16 by default), MSB first, one word per
//     cs_n frame.
//   * sclk is generated from clk: each sclk phase lasts CLK_DIV clk cycles, so
//     f_sclk = f_clk / (2 * CLK_DIV). sclk idles at cpol.
//   * Edges are named on the cpol-normalized clock (idle = 0), as in
//     spi_slave: a rising edge of the normalized clock is the "leading" edge
//     and a falling edge is the "trailing" edge.
//
//        cpha = 0: sample miso on the leading edge, shift mosi on the trailing
//                  edge. The first mosi bit is valid as soon as cs_n falls.
//        cpha = 1: shift mosi on the leading edge, sample miso on the
//                  trailing edge.
//
//   * A transfer starts when start is high while busy is low; tx_data is
//     captured in that cycle. start is ignored while busy is high.
//   * Frame timing, in sclk half periods (CLK_DIV clk cycles each):
//        cs_n falls -> 1 half period -> 2 * DATA_WIDTH sclk edges ->
//        1 half period -> cs_n rises -> 1 half period -> busy falls.
//   * After the last bit of a transfer is sampled, the received word is
//     copied to rx_data and rx_valid pulses high for one clk cycle. rx_data
//     holds its value until the next complete transfer.
//   * cpol and cpha must only change while busy is low.
//
// Timing: miso is sampled directly on clk with no synchronizer, so the slave
// must run on the same clk (as spi_slave does in the integration tests).
// spi_slave needs f_clk >= 8 * f_sclk, so keep CLK_DIV >= 4.

`default_nettype none

module spi_master #(
    parameter DATA_WIDTH = 16,
    parameter CLK_DIV    = 4,      // clk cycles per sclk half period, >= 1
    parameter CNT_BITS   = $clog2(DATA_WIDTH),
    parameter DIV_BITS   = (CLK_DIV > 1) ? $clog2(CLK_DIV) : 1
    )(
  input  logic                  clk,
  input  logic                  rst,       // synchronous, active high
  input  logic                  cpol,      // sclk idle level
  input  logic                  cpha,      // 0: sample on leading edge, 1: on trailing edge
  // SPI bus
  output logic                  sclk,
  output logic                  cs_n,
  output logic                  mosi,
  input  logic                  miso,
  // Host side
  input  logic                  start,     // begin a transfer when not busy
  input  logic [DATA_WIDTH-1:0] tx_data,   // word sent on mosi
  output logic                  busy,      // high from start until the frame ends
  output logic [DATA_WIDTH-1:0] rx_data,   // last complete word received on miso
  output logic                  rx_valid   // one-cycle pulse when rx_data updates
);

  localparam int                   EDGE_BITS = $clog2(2 * DATA_WIDTH);
  localparam logic [CNT_BITS-1:0]  LAST_BIT  = CNT_BITS'(DATA_WIDTH - 1);
  localparam logic [EDGE_BITS-1:0] LAST_EDGE = EDGE_BITS'(2 * DATA_WIDTH - 1);
  localparam logic [DIV_BITS-1:0]  DIV_LAST  = DIV_BITS'(CLK_DIV - 1);

  typedef enum logic [2:0] {
    IDLE,    // cs_n high, waiting for start
    LEAD,    // cs_n low, first bit set up before the first sclk edge
    XFER,    // toggling sclk
    TRAIL,   // last sclk edge done, cs_n still low
    GAP      // cs_n high, minimum deselect time before the next frame
  } state_t;

  state_t state;

  // ---------------------------------------------------------------------------
  // Half-period timer: tick marks the last clk cycle of each sclk phase.
  // ---------------------------------------------------------------------------
  logic [DIV_BITS-1:0] div_cnt;
  logic                tick;

  assign tick = (state != IDLE) && (div_cnt == DIV_LAST);

  always_ff @(posedge clk) begin
    if (rst || state == IDLE || tick) div_cnt <= '0;
    else                              div_cnt <= div_cnt + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Edge decoding on the cpol-normalized clock (idle = 0). An edge signal is
  // high in the clk cycle at whose end sclk toggles.
  // ---------------------------------------------------------------------------
  logic sclk_n;
  logic leading_edge, trailing_edge;
  logic sample_edge, shift_edge;

  assign sclk_n        = sclk ^ cpol;
  assign leading_edge  = (state == XFER) & tick & ~sclk_n;
  assign trailing_edge = (state == XFER) & tick &  sclk_n;
  assign sample_edge   = cpha ? trailing_edge : leading_edge;
  assign shift_edge    = cpha ? leading_edge  : trailing_edge;

  // ---------------------------------------------------------------------------
  // Frame control and shift registers
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] rx_sr, tx_sr;
  logic [CNT_BITS-1:0]   bit_cnt;          // bits sampled so far in this word
  logic [EDGE_BITS-1:0]  edge_cnt;         // sclk edges so far in this word
  logic                  word_done;

  assign word_done = sample_edge & (bit_cnt == LAST_BIT);

  always_ff @(posedge clk) begin
    if (rst) begin
      state    <= IDLE;
      sclk     <= cpol;
      cs_n     <= 1'b1;
      rx_sr    <= '0;
      tx_sr    <= '0;
      bit_cnt  <= '0;
      edge_cnt <= '0;
      rx_data  <= '0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;

      case (state)
        IDLE: begin
          sclk     <= cpol;
          cs_n     <= 1'b1;
          bit_cnt  <= '0;
          edge_cnt <= '0;
          if (start) begin
            tx_sr <= tx_data;                // MSB is on mosi when cs_n falls
            cs_n  <= 1'b0;
            state <= LEAD;
          end
        end

        LEAD: if (tick) state <= XFER;

        XFER: begin
          if (tick) begin
            sclk     <= ~sclk;
            edge_cnt <= edge_cnt + 1'b1;
            if (edge_cnt == LAST_EDGE) state <= TRAIL;
          end

          if (sample_edge) begin
            rx_sr   <= {rx_sr[DATA_WIDTH-2:0], miso};
            bit_cnt <= word_done ? '0 : bit_cnt + 1'b1;
          end

          if (word_done) begin
            rx_data  <= {rx_sr[DATA_WIDTH-2:0], miso};
            rx_valid <= 1'b1;
          end

          // Edge 0 is the cpha = 1 leading edge that presents the MSB, which
          // is already in place. The last edge is the cpha = 0 trailing edge
          // after the final sample, so mosi is left alone through the hold.
          if (shift_edge && edge_cnt != '0 && edge_cnt != LAST_EDGE)
            tx_sr <= {tx_sr[DATA_WIDTH-2:0], 1'b0};
        end

        TRAIL: if (tick) begin
          cs_n  <= 1'b1;
          state <= GAP;
        end

        GAP: if (tick) state <= IDLE;

        default: state <= IDLE;
      endcase
    end
  end

  assign mosi = tx_sr[DATA_WIDTH-1];
  assign busy = (state != IDLE);

endmodule

`default_nettype wire
