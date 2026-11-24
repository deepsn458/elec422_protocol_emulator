// pio_spi_top - one PIO state machine behind an SPI slave
//
//   SPI host -> spi_slave -> instruction SRAM (while loading)
//                         -> TX FIFO -> sm_no_smx_instr -> RX FIFO -> spi_slave -> SPI host
//                                       sm_no_smx_instr <-> gpio_controller <-> pads
//
// Program load (same steering as tb_spi_imem_sm.sv):
//   * spi_slave counts received words and latches `loaded` after
//     IMEM_XFER_CNT (40) of them: 32 instruction slots + 8 config words
//     (the assembler's hex image, in order).
//   * !loaded: each word (rx_valid) is written to the SRAM at load_addr
//     (0..39). The TX FIFO gets nothing, and the SM is held in reset.
//   *  loaded: each word is pushed into the TX FIFO, and the SRAM address /
//     read enable come from the SM.
//   * `loaded` drives the SM's imem_loaded. The SM leaves reset one cycle
//     after it (its loaded_q), boots from the config words at 32-39 and runs.
//     Only rst reloads: after rst the next 40 words are a new program.
//
// SPI frames are full duplex. While running, every frame pushes the host's
// word into the TX FIFO (dropped if the FIFO is full) and returns the oldest
// RX FIFO word on miso, or 0 if the RX FIFO was empty when the frame started.
// The returned word is popped when the frame completes (rx_valid). A word
// the SM pushes mid-frame waits for the next frame. Frames cut short by cs_n
// rising pop nothing. cs_n must rise between words (spi_master does): with
// cs_n held low, spi_slave reloads tx_data on the last bit, before the pop.
//
// TX FIFO fall-through: the SM pops and reads tx_data in the same cycle, so
// tx_data comes from fifo.sv's interim combinational `head` port (see
// tb_imem_to_gpio.sv). The RX FIFO also feeds spi_slave from `head`.
//
// IRQ flags: a plain register the SM sets and clears (there is no IRQ block
// yet); irq_flags is exported for observation.

`default_nettype none

module pio_spi_top #(
    parameter logic [1:0] SM_ID   = 2'd0,
    parameter int DATA_WIDTH      = 16,
    parameter int FIFO_DEPTH      = 4,
    parameter int IMEM_XFER_CNT   = 40,      // 32 program slots + 8 config words
    parameter int SYNC_STAGES     = 2,       // must match spi_slave's
    // GPIO pin map (gpio_controller defaults)
    parameter logic [DATA_WIDTH-1:0] IN_ONLY  = 16'h000F,
    parameter logic [DATA_WIDTH-1:0] BIDIR    = 16'h0FF0,
    parameter logic [DATA_WIDTH-1:0] OUT_ONLY = 16'hF000,
    parameter logic [DATA_WIDTH-1:0] SAFE_OUT = '0
)(
    input  logic                  clk,
    input  logic                  rst,           // synchronous, active high

    // SPI bus (asynchronous to clk)
    input  logic                  cpol,
    input  logic                  cpha,
    input  logic                  sclk,
    input  logic                  cs_n,
    input  logic                  mosi,
    output logic                  miso,
    output logic                  miso_oe,

    // SM control
    input  logic                  en,            // SM_ENABLE
    input  logic                  restart,       // SM_RESTART, one-cycle pulse
    input  logic                  clkdiv_restart,// CLKDIV_RESTART, one-cycle pulse
    output logic                  loaded,        // program loaded, SM released

    // GPIO pads and fault status
    input  logic [DATA_WIDTH-1:0] pad_in,
    output logic [DATA_WIDTH-1:0] pad_out,
    output logic [DATA_WIDTH-1:0] pad_oe,
    input  logic                  clr_fault,     // one-cycle pulse
    output logic                  fault,         // sticky
    output logic [2:0]            fault_cause,   // sticky {read, dir, drive}

    output logic [7:0]            irq_flags
);

    localparam int DEPTH_BITS = $clog2(FIFO_DEPTH);

    // ------------------------------------------------------------------------
    // SPI slave
    // ------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] spi_rx_data;
    logic                  spi_rx_valid;
    logic [DATA_WIDTH-1:0] spi_tx_data;

    spi_slave #(
        .DATA_WIDTH(DATA_WIDTH),
        .IMEM_XFER_CNT(IMEM_XFER_CNT),
        .SYNC_STAGES(SYNC_STAGES)
    ) u_spi (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .miso_oe(miso_oe),
        .tx_data(spi_tx_data),
        .rx_data(spi_rx_data),
        .rx_valid(spi_rx_valid),
        .loaded(loaded)
    );

    // ------------------------------------------------------------------------
    // Load / run steering
    // ------------------------------------------------------------------------
    logic       imem_we;
    logic       tx_we;
    logic [5:0] load_addr;

    assign imem_we = spi_rx_valid & ~loaded;
    assign tx_we   = spi_rx_valid &  loaded;

    always_ff @(posedge clk) begin
        if (rst)          load_addr <= '0;
        else if (imem_we) load_addr <= load_addr + 1'b1;
    end

    // ------------------------------------------------------------------------
    // Instruction memory (IHP 64x16 SRAM)
    // ------------------------------------------------------------------------
    logic [5:0]  sm_mem_addr;
    logic        sm_read_en;
    logic [5:0]  imem_addr;
    logic        imem_ren;
    logic [15:0] instr;

    assign imem_addr = loaded ? sm_mem_addr : load_addr;
    assign imem_ren  = loaded & sm_read_en;

    RM_IHPSG13_1P_64x16_c2 u_imem (
        .A_CLK(clk),
        .A_MEN(1'b1),
        .A_WEN(imem_we),
        .A_REN(imem_ren),
        .A_ADDR(imem_addr),
        .A_DIN(spi_rx_data[15:0]),
        .A_DLY(1'b1),
        .A_DOUT(instr)
    );

    // ------------------------------------------------------------------------
    // TX FIFO (SPI host -> SM)
    // ------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] tx_data;
    logic                  tx_pop;
    logic [DEPTH_BITS:0]   tx_wptr, tx_rptr, tx_count;
    logic                  tx_empty;

    fifo #(.DEPTH(FIFO_DEPTH), .DATA_WIDTH(DATA_WIDTH)) u_tx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(spi_rx_data),
        .w_en(tx_we),
        .r_en(tx_pop),
        .d_out(),
        .head(tx_data),                  // interim fall-through read
        .wptr(tx_wptr),
        .rptr(tx_rptr)
    );
    assign tx_count = tx_wptr - tx_rptr;
    assign tx_empty = (tx_count == '0);

    // ------------------------------------------------------------------------
    // RX FIFO (SM -> SPI host)
    // ------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] rx_data;
    logic                  rx_push;
    logic                  rx_pop;
    logic [DATA_WIDTH-1:0] rx_head;
    logic [DEPTH_BITS:0]   rx_wptr, rx_rptr, rx_count;
    logic                  rx_empty, rx_full;

    fifo #(.DEPTH(FIFO_DEPTH), .DATA_WIDTH(DATA_WIDTH)) u_rx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(rx_data),
        .w_en(rx_push),
        .r_en(rx_pop),
        .d_out(),
        .head(rx_head),
        .wptr(rx_wptr),
        .rptr(rx_rptr)
    );
    assign rx_count = rx_wptr - rx_rptr;
    assign rx_empty = (rx_count == '0);
    assign rx_full  = (rx_count == (DEPTH_BITS+1)'(FIFO_DEPTH));

    // miso word: spi_slave loads tx_data into its shift register on every
    // cycle its synchronized cs_n is high. cs_n is synchronized here the same
    // way, so miso_word_valid records whether the word in that shift register
    // at the start of the frame came from the RX FIFO. Only then is it popped.
    logic [SYNC_STAGES-1:0] cs_n_sync;
    logic                   cs_n_s;
    logic                   miso_word_valid;

    always_ff @(posedge clk) begin
        if (rst) cs_n_sync <= '1;
        else     cs_n_sync <= {cs_n_sync[SYNC_STAGES-2:0], cs_n};
    end
    assign cs_n_s = cs_n_sync[SYNC_STAGES-1];

    always_ff @(posedge clk) begin
        if (rst)         miso_word_valid <= 1'b0;
        else if (cs_n_s) miso_word_valid <= ~rx_empty;
    end

    assign spi_tx_data = rx_empty ? '0 : rx_head;
    assign rx_pop      = spi_rx_valid & miso_word_valid;

    // ------------------------------------------------------------------------
    // GPIO controller
    // ------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] gpio_in, pins_re, pins_we, pins_wdata, dirs_we, dirs_wdata;
    logic                  gpio_fault;

    gpio_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .IN_ONLY(IN_ONLY),
        .BIDIR(BIDIR),
        .OUT_ONLY(OUT_ONLY),
        .SAFE_OUT(SAFE_OUT)
    ) u_gpio (
        .clk(clk),
        .rst(rst),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .pins_re(pins_re),
        .gpio_in(gpio_in),
        .gpio_fault(gpio_fault),
        .clr_fault(clr_fault),
        .fault(fault),
        .fault_cause(fault_cause),
        .pad_in(pad_in),
        .pad_out(pad_out),
        .pad_oe(pad_oe)
    );

    // ------------------------------------------------------------------------
    // IRQ flags
    // ------------------------------------------------------------------------
    logic [7:0] irq_set, irq_clr;

    always_ff @(posedge clk) begin
        if (rst) irq_flags <= '0;
        else     irq_flags <= (irq_flags & ~irq_clr) | irq_set;
    end

    // ------------------------------------------------------------------------
    // State machine
    // ------------------------------------------------------------------------
    sm_no_smx_instr #(.SM_ID(SM_ID), .DATA_WIDTH(DATA_WIDTH)) u_sm (
        .clk(clk),
        .external_rst(rst),
        .imem_loaded(loaded),
        .en(en),
        .restart(restart),
        .clkdiv_restart(clkdiv_restart),
        .mem_addr(sm_mem_addr),
        .read_en(sm_read_en),
        .instr(instr),
        .tx_data(tx_data),
        .tx_empty(tx_empty),
        .tx_level(3'(tx_count)),
        .tx_pop(tx_pop),
        .rx_data(rx_data),
        .rx_full(rx_full),
        .rx_level(3'(rx_count)),
        .rx_push(rx_push),
        .gpio_in(gpio_in),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .pins_re(pins_re),
        .gpio_fault(gpio_fault),
        .irq_flags(irq_flags),
        .irq_set(irq_set),
        .irq_clr(irq_clr)
    );

endmodule

`default_nettype wire
