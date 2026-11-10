// spi_slave - SPI peripheral (slave) with settable CPOL / CPHA
//
//   * Transfers are DATA_WIDTH bits (16 by default), MSB first.
//   * sclk, cs_n and mosi come from an external master and are asynchronous
//     to clk. Each passes through the same SYNC_STAGES flip-flop synchronizer,
//     so the three stay aligned with each other after synchronization.
//   * Edges of the synchronized sclk are found by comparing it with its value
//     on the previous clk cycle. sclk is first XORed with cpol so the idle
//     level is always 0; then a rising edge of the normalized clock is the
//     "leading" edge and a falling edge is the "trailing" edge.
//
//        cpha = 0: sample mosi on the leading edge, shift miso on the trailing
//                  edge. The first miso bit is valid as soon as cs_n falls.
//        cpha = 1: shift miso on the leading edge, sample mosi on the
//                  trailing edge.
//
//   * After the last bit of a transfer is sampled, the received word is
//     copied to rx_data and rx_valid pulses high for one clk cycle. rx_data
//     holds its value until the next complete transfer.
//   * tx_data is loaded into the transmit shift register while cs_n is high
//     and again when the last bit of each word is sampled (the same cycle
//     rx_valid rises), so back-to-back words with cs_n held low work. For
//     back-to-back words the host must put the next word on tx_data before
//     the current word ends. A transfer cut short by cs_n rising is discarded.
//   * cpol and cpha must only change while cs_n is high.
//
// Timing: the synchronizer and edge detector add SYNC_STAGES + 1 clk cycles
// of latency, and both sclk phases must last long enough to be seen. Keep
// f_clk >= 8 * f_sclk so miso settles well before the master samples it.

`default_nettype none

module spi_slave #(
    parameter DATA_WIDTH  = 16,
    parameter SYNC_STAGES = 2,
    parameter CNT_BITS    = $clog2(DATA_WIDTH)
    )(
  input  logic                  clk,
  input  logic                  rst,       // synchronous, active high
  input  logic                  cpol,      // sclk idle level
  input  logic                  cpha,      // 0: sample on leading edge, 1: on trailing edge
  // SPI bus (asynchronous to clk)
  input  logic                  sclk,
  input  logic                  cs_n,
  input  logic                  mosi,
  output logic                  miso,
  output logic                  miso_oe,   // drive miso only while selected
  // Host side
  input  logic [DATA_WIDTH-1:0] tx_data,   // word sent on miso
  output logic [DATA_WIDTH-1:0] rx_data,   // last complete word received on mosi
  output logic                  rx_valid   // one-cycle pulse when rx_data updates
);

  localparam logic [CNT_BITS-1:0] LAST_BIT = CNT_BITS'(DATA_WIDTH - 1);

  // ---------------------------------------------------------------------------
  // Synchronizers: [0] is the first (metastable) stage, [SYNC_STAGES-1] is safe.
  // ---------------------------------------------------------------------------
  logic [SYNC_STAGES-1:0] sclk_sync, cs_n_sync, mosi_sync;

  always_ff @(posedge clk) begin
    if (rst) begin
      sclk_sync <= {SYNC_STAGES{cpol}};
      cs_n_sync <= '1;
      mosi_sync <= '0;
    end else begin
      sclk_sync <= {sclk_sync[SYNC_STAGES-2:0], sclk};
      cs_n_sync <= {cs_n_sync[SYNC_STAGES-2:0], cs_n};
      mosi_sync <= {mosi_sync[SYNC_STAGES-2:0], mosi};
    end
  end

  logic sclk_s, cs_n_s, mosi_s;
  assign sclk_s = sclk_sync[SYNC_STAGES-1];
  assign cs_n_s = cs_n_sync[SYNC_STAGES-1];
  assign mosi_s = mosi_sync[SYNC_STAGES-1];

  // ---------------------------------------------------------------------------
  // Edge detection on the cpol-normalized clock (idle = 0).
  // ---------------------------------------------------------------------------
  logic sclk_n, sclk_n_d;
  logic leading_edge, trailing_edge;
  logic sample_edge, shift_edge;
  logic active;

  assign sclk_n = sclk_s ^ cpol;

  always_ff @(posedge clk) begin
    if (rst) sclk_n_d <= 1'b0;
    else     sclk_n_d <= sclk_n;
  end

  assign active        = ~cs_n_s;
  assign leading_edge  = active &  sclk_n & ~sclk_n_d;
  assign trailing_edge = active & ~sclk_n &  sclk_n_d;
  assign sample_edge   = cpha ? trailing_edge : leading_edge;
  assign shift_edge    = cpha ? leading_edge  : trailing_edge;

  // ---------------------------------------------------------------------------
  // Shift registers
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] rx_sr, tx_sr;
  logic [CNT_BITS-1:0]   bit_cnt;          // bits sampled so far in this word
  logic                  word_done;

  assign word_done = sample_edge & (bit_cnt == LAST_BIT);

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_sr    <= '0;
      tx_sr    <= '0;
      bit_cnt  <= '0;
      rx_data  <= '0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;

      if (!active) begin
        // Idle: drop any partial word and keep the next word ready on miso.
        bit_cnt <= '0;
        tx_sr   <= tx_data;
      end else begin
        if (sample_edge) begin
          rx_sr   <= {rx_sr[DATA_WIDTH-2:0], mosi_s};
          bit_cnt <= word_done ? '0 : bit_cnt + 1'b1;
        end

        if (word_done) begin
          rx_data  <= {rx_sr[DATA_WIDTH-2:0], mosi_s};
          rx_valid <= 1'b1;
          tx_sr    <= tx_data;               // next word for back-to-back transfers
        end else if (shift_edge && bit_cnt != '0) begin
          // bit_cnt == 0 marks the cpha = 1 leading edge that presents the
          // MSB, which is already in place, so there is nothing to shift.
          tx_sr <= {tx_sr[DATA_WIDTH-2:0], 1'b0};
        end
      end
    end
  end

  assign miso    = tx_sr[DATA_WIDTH-1];
  assign miso_oe = active;

endmodule

`default_nettype wire
