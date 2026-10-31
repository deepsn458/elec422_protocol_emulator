// sm - one PIO state machine (RP2040 datasheet, chapter 3)
//      instructions are only going to be executed from instruction memory
// Glue logic around the state machine's datapath blocks:
//   * decode   - instruction fields, delay/side-set split, IRQ index
//   * isr      - input shift register  (IN, PUSH, autopush, MOV ISR, OUT ISR)
//   * osr      - output shift register (OUT, PULL, autopull, MOV OSR)
//   * regfile  - scratch registers X (reg 1) and Y (reg 2); reg 0 reads 0
//   * clockdiv - 16.8 fractional clock divider -> clock enable 'tick'
//   * program_counter - the PC register
//
// The instruction memory lives outside this module:
//   * mem_addr / read_en / instr: the PC drives the address, memory returns
//     the instruction stored there (combinational read).
//   * branch_en / branch_addr (internal): tell the PC what to load next. When
//     branch_en is low the PC increments (31 wraps to 0). branch_addr always holds the
//     next PC, so stalls, delay cycles and disabled cycles hold the PC by
//     "branching" to the current address, and wrap is a branch to
//     WRAP_BOTTOM.
//
// One instruction runs per enabled cycle. An instruction that cannot finish
// (WAIT not met, blocking PUSH/PULL on a full/empty FIFO, autopush/autopull
// stall, IRQ WAIT) stalls: it has no effect except side-set, and runs again
// on the next enabled cycle. Delay cycles start after it completes.
//
// Instruction word: [15:13] opcode, [12:8] delay/side-set, [7:5] arg1,
// [4:0] arg2. Configuration inputs use the RP2040 SMx_CLKDIV, SMx_EXECCTRL,
// SMx_SHIFTCTRL and SMx_PINCTRL bit layouts.
//
// Differences from RP2040: OUT_STICKY, INLINE_OUT_EN and FJOIN are not
// implemented, and SM_RESTART also clears the OSR contents (RP2040 keeps
// them). There is no SMx_INSTR (forced instruction) port, and OUT EXEC /
// MOV EXEC are not supported: every instruction comes from instruction memory.

`default_nettype none

module sm_no_smx_instr #(
  parameter logic [1:0] SM_ID = 2'd0,     // state machine number, for IRQ rel
  // Width of X, Y, ISR, OSR, the FIFO words and the GPIO buses. Must be a
  // power of two from 8 to 32 (5-bit instruction fields address up to 32).
  parameter int DATA_WIDTH = 16
) (
  input  logic        clk,
  input  logic        rst,                 // synchronous, active high

  // CTRL register
  input  logic        en,                  // SM_ENABLE
  input  logic        restart,             // SM_RESTART, one-cycle pulse
  input  logic        clkdiv_restart,      // CLKDIV_RESTART, one-cycle pulse

  // Per-SM configuration registers (RP2040 bit layout)
  input  logic [31:0] clkdiv,
  input  logic [31:0] execctrl,
  input  logic [31:0] shiftctrl,
  input  logic [31:0] pinctrl,

  // Instruction memory
  output logic [4:0]  mem_addr,            // = PC
  output logic        read_en,
  input  logic [15:0] instr,               // instruction memory[mem_addr]

  // TX FIFO (host -> SM), first-word fall-through
  input  logic [DATA_WIDTH-1:0] tx_data,   // oldest word, valid when !tx_empty
  input  logic        tx_empty,
  input  logic [2:0]  tx_level,            // words held, 0..4 (MOV STATUS)
  output logic        tx_pop,

  // RX FIFO (SM -> host)
  output logic [DATA_WIDTH-1:0] rx_data,
  input  logic        rx_full,
  input  logic [2:0]  rx_level,
  output logic        rx_push,

  // GPIO: DATA_WIDTH-bit write masks and data for pin levels and directions
  input  logic [DATA_WIDTH-1:0] gpio_in,
  output logic [DATA_WIDTH-1:0] pins_we,
  output logic [DATA_WIDTH-1:0] pins_wdata,
  output logic [DATA_WIDTH-1:0] dirs_we,
  output logic [DATA_WIDTH-1:0] dirs_wdata,

  // IRQ flags shared by all state machines
  input  logic [7:0]  irq_flags,
  output logic [7:0]  irq_set,
  output logic [7:0]  irq_clr
);

  // Counts (bit counts, thresholds, pin counts) run 0..DATA_WIDTH and need
  // CW bits; pin numbers and isr/osr shift amounts need DW_BITS bits.
  localparam int DW_BITS = $clog2(DATA_WIDTH);
  localparam int CW      = DW_BITS + 1;
  localparam logic [CW-1:0] FULL = DATA_WIDTH;
  localparam logic [DATA_WIDTH-1:0] ONE = 1;

  // OUT destinations
  localparam logic [2:0] OUT_PINS    = 3'd0;
  localparam logic [2:0] OUT_X       = 3'd1;
  localparam logic [2:0] OUT_Y       = 3'd2;
  localparam logic [2:0] OUT_PINDIRS = 3'd4;
  localparam logic [2:0] OUT_PC      = 3'd5;
  localparam logic [2:0] OUT_ISR     = 3'd6;
  localparam logic [2:0] OUT_EXEC    = 3'd7;

  // MOV destinations
  localparam logic [2:0] MOV_PINS = 3'd0;
  localparam logic [2:0] MOV_X    = 3'd1;
  localparam logic [2:0] MOV_Y    = 3'd2;
  localparam logic [2:0] MOV_EXEC = 3'd4;
  localparam logic [2:0] MOV_PC   = 3'd5;
  localparam logic [2:0] MOV_ISR  = 3'd6;
  localparam logic [2:0] MOV_OSR  = 3'd7;

  // SET destinations
  localparam logic [2:0] SET_PINS    = 3'd0;
  localparam logic [2:0] SET_X       = 3'd1;
  localparam logic [2:0] SET_Y       = 3'd2;
  localparam logic [2:0] SET_PINDIRS = 3'd4;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  // Low n bits set, n = 0..DATA_WIDTH (1 << DATA_WIDTH is 0, so 0 - 1 gives
  // all ones).
  function automatic logic [DATA_WIDTH-1:0] lowmask(input logic [CW-1:0] n);
    return (ONE << n) - ONE;
  endfunction

  // Rotate left by s: maps bit 0 to GPIO s, wrapping after the last GPIO.
  function automatic logic [DATA_WIDTH-1:0] rotl(input logic [DATA_WIDTH-1:0] v,
                                                 input logic [DW_BITS-1:0] s);
    return (v << s) | (v >> (FULL - CW'(s)));
  endfunction

  // Rotate right by s: GPIO s becomes bit 0.
  function automatic logic [DATA_WIDTH-1:0] rotr(input logic [DATA_WIDTH-1:0] v,
                                                 input logic [DW_BITS-1:0] s);
    return (v >> s) | (v << (FULL - CW'(s)));
  endfunction

  function automatic logic [DATA_WIDTH-1:0] bitrev(input logic [DATA_WIDTH-1:0] v);
    logic [DATA_WIDTH-1:0] r;
    for (int i = 0; i < DATA_WIDTH; i++)
      r[i] = v[DATA_WIDTH - 1 - i];
    return r;
  endfunction

  // Count clamped to DATA_WIDTH.
  function automatic logic [CW-1:0] clampw(input logic [5:0] n);
    return (n > FULL) ? FULL : n[CW-1:0];
  endfunction

  // 5-bit count/threshold field where 0 encodes 32, clamped to DATA_WIDTH.
  function automatic logic [CW-1:0] count32(input logic [4:0] n);
    return (n == 5'd0) ? FULL : clampw({1'b0, n});
  endfunction

  // ---------------------------------------------------------------------------
  // Configuration fields
  // ---------------------------------------------------------------------------

  logic        side_en, side_pindir;
  logic [DW_BITS-1:0] jmp_pin;
  logic [4:0]  wrap_top, wrap_bottom;
  logic        status_sel;
  logic [3:0]  status_n;
  logic [CW-1:0] pull_thresh, push_thresh;
  logic        out_dir, in_dir, autopull, autopush;
  logic [2:0]  sideset_count, set_count;
  logic [CW-1:0] out_count;
  logic [DW_BITS-1:0] in_base, sideset_base, set_base, out_base;
  logic [15:0] div_int;
  logic [7:0]  div_frac;

  assign side_en       = execctrl[30]; // if 1, the MSB of the delay/side-set field is used to enable/disable side set
  assign side_pindir   = execctrl[29]; // if 1, side-set data is asserted to pin dirs instead of pin values
  assign jmp_pin       = execctrl[24 +: DW_BITS]; // the gpio number to use as the jmp pin (mod DATA_WIDTH)
  assign wrap_top      = execctrl[16:12]; // after reaching this address, execution is wrapped to wrap_bottom 
  assign wrap_bottom   = execctrl[11:7]; // after reaching wrap_top, execution is wrapped to this instruction
  assign status_sel    = execctrl[4]; // if 1, use tx fifo level for comparison for MOV X, STATUS instr. Else use rx level
  assign status_n      = execctrl[3:0]; // The actual tx/rx fifo level to use as comparison

  assign pull_thresh   = count32(shiftctrl[29:25]); //num bits shifted out of osr before autopull or conditional pull will take place
  assign push_thresh   = count32(shiftctrl[24:20]); // same as above but for isr
  assign out_dir       = shiftctrl[19]; //left or right direction for output shift dir
  assign in_dir        = shiftctrl[18]; //same as above for isr
  assign autopull      = shiftctrl[17]; // enable or disable autopull
  assign autopush      = shiftctrl[16]; //enable or disable autopush

  assign sideset_count = (pinctrl[31:29] > 3'd5) ? 3'd5 : pinctrl[31:29]; //num bits to be used as sideset (max 5)
  assign set_count     = (pinctrl[28:26] > 3'd5) ? 3'd5 : pinctrl[28:26]; //how many pins are asserted by set (max 5)
  assign out_count     = clampw(pinctrl[25:20]); //num pins assered by OUT or MOV instructions (max DATA_WIDTH)
  // Pin numbers are 5-bit fields; only the low DW_BITS bits are used (mod DATA_WIDTH).
  assign in_base       = pinctrl[15 +: DW_BITS]; // base pin for input
  assign sideset_base  = pinctrl[10 +: DW_BITS];
  assign set_base      = pinctrl[5  +: DW_BITS];
  assign out_base      = pinctrl[0  +: DW_BITS];

  assign div_int       = clkdiv[31:16];
  assign div_frac      = clkdiv[15:8];

  // Instruction fields from u_decode
  logic [2:0] arg1;
  logic [4:0] arg2;
  logic [5:0] bit_count;         // IN/OUT bit count, 1..32

  // IN/OUT bit count clamped to DATA_WIDTH, and the isr/osr encoding of it
  // (DW_BITS bits, 0 = DATA_WIDTH).
  logic [CW-1:0]      io_count;
  logic [DW_BITS-1:0] io_n;

  assign io_count = clampw(bit_count);
  assign io_n     = io_count[DW_BITS-1:0];

  // ---------------------------------------------------------------------------
  // Submodules
  // ---------------------------------------------------------------------------

  logic        tick;

  // Program counter. pc_en is always high: the SM holds the PC on stalled,
  // delayed and disabled cycles by branching to the current address.
  logic [4:0]  pc;
  logic        branch_en;          // 1 = PC loads branch_addr
  logic [4:0]  branch_addr;        // next PC

  program_counter #(
    .MEM_ADDR_WIDTH (5),
    .BYTE_INCREMENT (1),
    .SRAM_BYTE_WIDTH(1)
  ) u_pc (
    .clk        (clk),
    .rst_n      (!rst),
    .pc_en      (1'b1),
    .branch_en  (branch_en),
    .branch_addr(branch_addr),
    .pc         (pc),
    .read_en    (read_en)
  );

  assign mem_addr = pc;

  clockdiv u_clockdiv (
    .clk      (clk),
    .rst      (rst | clkdiv_restart),
    .div_int  (div_int),
    .div_frac (div_frac),
    .tick     (tick)
  );

  // Scratch registers. Port 1 always reads X, port 2 always reads Y.
  // The regfile writes on the falling clock edge.
  logic        xy_we;
  logic [1:0]  xy_addr;
  logic [DATA_WIDTH-1:0] xy_wdata;
  logic [DATA_WIDTH-1:0] x, y;

  regfile #(
    .REG_WIDTH (DATA_WIDTH),
    .NUMREGS   (3)
  ) u_xy (
    .clk       (clk),
    .w_en      (xy_we),
    .src_reg_1 (2'd1),
    .src_reg_2 (2'd2),
    .dest_reg  (xy_addr),
    .w_data    (xy_wdata),
    .r_data_1  (x),
    .r_data_2  (y)
  );

  // ISR. Its synchronous reset also serves as the PUSH / autopush clear.
  logic        isr_clear, isr_load, isr_shift;
  logic [CW-1:0]         isr_load_cnt;
  logic [DATA_WIDTH-1:0] isr_din;
  logic [DATA_WIDTH-1:0] isr_q, isr_shift_q;
  logic [CW-1:0]         isr_cnt, isr_shift_cnt;

  isr #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_isr (
    .clk       (clk),
    .rst       (rst | restart | isr_clear),
    .ce        (1'b1),
    .load      (isr_load),
    .load_cnt  (isr_load_cnt),
    .shift     (isr_shift),
    .n         (io_n),
    .dir       (in_dir),
    .din       (isr_din),
    .q         (isr_q),
    .cnt       (isr_cnt),
    .shift_q   (isr_shift_q),
    .shift_cnt (isr_shift_cnt)
  );

  logic        osr_load, osr_shift;
  logic [DATA_WIDTH-1:0] osr_din;
  logic [DATA_WIDTH-1:0] osr_q, out_data;
  logic [CW-1:0]         osr_cnt, osr_shift_cnt;

  osr #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_osr (
    .clk       (clk),
    .rst       (rst | restart),
    .ce        (1'b1),
    .load      (osr_load),
    .shift     (osr_shift),
    .n         (io_n),
    .dir       (out_dir),
    .din       (osr_din),
    .q         (osr_q),
    .shifted   (out_data),
    .cnt       (osr_cnt),
    .shift_cnt (osr_shift_cnt)
  );

  // ---------------------------------------------------------------------------
  // Instruction source and execution enable
  // ---------------------------------------------------------------------------

  logic [4:0]  delay_cnt;      // delay cycles left after the last instruction
  logic        irq_waiting;    // IRQ WAIT has set its flag, waiting for clear

  logic        ce;             // program execution enable for this cycle
  logic        active;         // an instruction is executing this cycle
  logic        stall;          // ...but cannot complete
  logic        done;           // ...and completes

  assign ce          = en & tick;
  assign active      = ce && (delay_cnt == 5'd0);
  assign done        = active && !stall;

  // ---------------------------------------------------------------------------
  // Decode
  // ---------------------------------------------------------------------------

  logic       is_jmp, is_wait, is_in, is_out, is_push, is_pull, is_mov, is_irq, is_set;
  logic       blk, if_flag;      // PUSH/PULL Block and IfFull/IfEmpty bits
  logic       irq_clr_bit, irq_wait_bit;
  logic [1:0] mov_op;
  logic [2:0] mov_srcsel;        // MOV source
  logic [1:0] wait_src;          // WAIT source
  logic       wait_pol;          // WAIT polarity
  logic [4:0] delay;
  logic       ss_valid;          // instruction performs a side-set
  logic [2:0] ss_bits;           // side-set data bits, 0..5
  logic [4:0] ss_value;          // side-set data, right-aligned
  logic [2:0] irq_idx;
  logic [7:0] irq_bit;

  decode #(
    .SM_ID (SM_ID)
  ) u_decode (
    .ins           (instr),
    .sideset_count (sideset_count),
    .side_en       (side_en),
    .arg1          (arg1),
    .arg2          (arg2),
    .bit_count     (bit_count),
    .is_jmp        (is_jmp),
    .is_wait       (is_wait),
    .is_in         (is_in),
    .is_out        (is_out),
    .is_push       (is_push),
    .is_pull       (is_pull),
    .is_mov        (is_mov),
    .is_irq        (is_irq),
    .is_set        (is_set),
    .blk           (blk),
    .if_flag       (if_flag),
    .irq_clr_bit   (irq_clr_bit),
    .irq_wait_bit  (irq_wait_bit),
    .mov_op        (mov_op),
    .mov_srcsel    (mov_srcsel),
    .wait_src      (wait_src),
    .wait_pol      (wait_pol),
    .delay         (delay),
    .ss_valid      (ss_valid),
    .ss_bits       (ss_bits),
    .ss_value      (ss_value),
    .irq_idx       (irq_idx),
    .irq_bit       (irq_bit)
  );

  // Side-set data and mask, mapped onto the GPIOs from SIDESET_BASE.
  logic [DATA_WIDTH-1:0] ss_mask, ss_data;

  assign ss_mask = rotl(lowmask(CW'(ss_bits)), sideset_base);
  assign ss_data = rotl(DATA_WIDTH'(ss_value), sideset_base) & ss_mask;

  // ---------------------------------------------------------------------------
  // Operands
  // ---------------------------------------------------------------------------

  logic [DATA_WIDTH-1:0] in_pins;  // GPIOs rotated so IN_BASE is bit 0
  logic [DATA_WIDTH-1:0] status;
  logic [DATA_WIDTH-1:0] in_src, mov_src, mov_val;

  assign in_pins = rotr(gpio_in, in_base);
  assign status  = ({1'b0, (status_sel ? rx_level : tx_level)} < status_n) ? '1 : '0;

  always_comb begin
    case (arg1)                  // IN source
      3'd0:    in_src = in_pins;
      3'd1:    in_src = x;
      3'd2:    in_src = y;
      3'd6:    in_src = isr_q;
      3'd7:    in_src = osr_q;
      default: in_src = '0;      // NULL, reserved
    endcase

    case (mov_srcsel)
      3'd0:    mov_src = in_pins;
      3'd1:    mov_src = x;
      3'd2:    mov_src = y;
      3'd5:    mov_src = status;
      3'd6:    mov_src = isr_q;
      3'd7:    mov_src = osr_q;
      default: mov_src = '0;     // NULL, reserved
    endcase

    case (mov_op)
      2'd1:    mov_val = ~mov_src;
      2'd2:    mov_val = bitrev(mov_src);
      default: mov_val = mov_src;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Conditions and stalls
  // ---------------------------------------------------------------------------

  // The regfile writes X/Y at the falling edge, so by the next rising edge
  // X and Y already show a JMP X--/Y-- decrement. Sample the "nonzero before
  // decrement" test at the same falling edge.
  logic x_nz_q, y_nz_q;

  always_ff @(negedge clk) begin
    x_nz_q <= (x != '0);
    y_nz_q <= (y != '0);
  end

  logic jmp_cond;
  always_comb begin
    case (arg1)
      3'd0:    jmp_cond = 1'b1;                     // always
      3'd1:    jmp_cond = (x == '0);                // !X
      3'd2:    jmp_cond = x_nz_q;                   // X--
      3'd3:    jmp_cond = (y == '0);                // !Y
      3'd4:    jmp_cond = y_nz_q;                   // Y--
      3'd5:    jmp_cond = (x != y);                 // X!=Y
      3'd6:    jmp_cond = gpio_in[jmp_pin];         // PIN
      default: jmp_cond = (osr_cnt < pull_thresh);  // !OSRE
    endcase
  end

  logic wait_bit;
  always_comb begin
    case (wait_src)
      2'd0:    wait_bit = gpio_in[arg2[DW_BITS-1:0]];
      2'd1:    wait_bit = in_pins[arg2[DW_BITS-1:0]];
      2'd2:    wait_bit = irq_flags[irq_idx];
      default: wait_bit = wait_pol;                 // reserved: never waits
    endcase
  end

  logic in_push;      // IN reaches the autopush threshold
  logic out_empty;    // OUT with autopull finds the OSR already empty
  logic out_refill;   // OUT with autopull empties the OSR and refills it
  logic push_skip;    // PUSH IFFULL below threshold: no-op
  logic pull_skip;    // PULL IFEMPTY (or autopull) with data left: no-op

  assign in_push    = autopush && (isr_shift_cnt >= push_thresh);
  assign out_empty  = autopull && (osr_cnt >= pull_thresh);
  assign out_refill = autopull && (osr_shift_cnt >= pull_thresh) && !tx_empty;
  assign push_skip  = if_flag && (isr_cnt < push_thresh);
  assign pull_skip  = (if_flag || autopull) && (osr_cnt < pull_thresh);

  always_comb begin
    case (1'b1)
      is_wait: stall = (wait_bit != wait_pol);
      is_in:   stall = in_push && rx_full;
      is_out:  stall = out_empty;
      is_push: stall = !push_skip && blk && rx_full;
      is_pull: stall = !pull_skip && blk && tx_empty;
      is_irq:  stall = !irq_clr_bit && irq_wait_bit && (!irq_waiting || irq_flags[irq_idx]);
      default: stall = 1'b0;     // JMP, MOV, SET never stall
    endcase
  end

  // ---------------------------------------------------------------------------
  // Datapath control
  // ---------------------------------------------------------------------------

  // ISR
  assign isr_shift    = done && is_in && !in_push;
  assign isr_clear    = done && ((is_in && in_push) || (is_push && !push_skip));
  assign isr_load     = done && ((is_mov && arg1 == MOV_ISR) || (is_out && arg1 == OUT_ISR));
  assign isr_load_cnt = is_out ? io_count : '0;
  assign isr_din      = is_in  ? in_src :
                        is_mov ? mov_val : out_data;

  assign rx_push = done && ((is_in && in_push) || (is_push && !push_skip && !rx_full));
  assign rx_data = is_in ? isr_shift_q : isr_q;

  // OSR. Autopull refills on a stalled OUT, together with the OUT that
  // empties the OSR, or on any other enabled cycle (background refill).
  logic osr_busy, pull_fifo, pull_x, mov_osr, bg_refill;

  assign osr_busy  = active && (is_out || is_pull || (is_mov && arg1 == MOV_OSR));
  assign pull_fifo = done && is_pull && !pull_skip && !tx_empty;
  assign pull_x    = done && is_pull && !pull_skip &&  tx_empty;   // noblock: OSR = X
  assign mov_osr   = done && is_mov && arg1 == MOV_OSR;
  assign bg_refill = ce && !osr_busy && out_empty && !tx_empty;

  assign tx_pop    = (active && is_out && out_empty && !tx_empty)
                   || (done && is_out && out_refill)
                   || pull_fifo
                   || bg_refill;
  assign osr_shift = done && is_out;
  assign osr_load  = tx_pop || pull_x || mov_osr;
  assign osr_din   = mov_osr ? mov_val :
                     pull_x  ? x       : tx_data;

  // Scratch registers
  always_comb begin
    xy_we    = 1'b0;
    xy_addr  = 2'd0;
    xy_wdata = '0;
    if (done) begin
      if (is_jmp && arg1 == 3'd2) begin                        // X--
        xy_we = 1'b1;  xy_addr = 2'd1;  xy_wdata = x - ONE;
      end else if (is_jmp && arg1 == 3'd4) begin               // Y--
        xy_we = 1'b1;  xy_addr = 2'd2;  xy_wdata = y - ONE;
      end else if ((is_out || is_mov || is_set) && (arg1 == 3'd1 || arg1 == 3'd2)) begin
        xy_we    = 1'b1;
        xy_addr  = (arg1 == 3'd1) ? 2'd1 : 2'd2;
        xy_wdata = is_out ? out_data :
                   is_mov ? mov_val  : DATA_WIDTH'(arg2);
      end
    end
  end

  // Pins. OUT and MOV use the OUT mapping, SET the SET mapping. Side-set
  // happens on every active cycle, stalled or not, and wins on overlap.
  logic        os_pins, os_dirs;
  logic [DATA_WIDTH-1:0] os_raw, os_mask, os_data;
  logic [DATA_WIDTH-1:0] side_pins_m, side_dirs_m, os_pins_m, os_dirs_m;

  assign os_pins = done && ((is_out && arg1 == OUT_PINS) || (is_mov && arg1 == MOV_PINS) ||
                            (is_set && arg1 == SET_PINS));
  assign os_dirs = done && ((is_out && arg1 == OUT_PINDIRS) || (is_set && arg1 == SET_PINDIRS));
  assign os_raw  = is_set ? DATA_WIDTH'(arg2) :
                   is_out ? out_data : mov_val;
  assign os_mask = rotl(lowmask(is_set ? CW'(set_count) : out_count),
                        is_set ? set_base : out_base);
  assign os_data = rotl(os_raw, is_set ? set_base : out_base) & os_mask;

  assign side_pins_m = (active && ss_valid && !side_pindir) ? ss_mask : '0;
  assign side_dirs_m = (active && ss_valid &&  side_pindir) ? ss_mask : '0;
  assign os_pins_m   = os_pins ? os_mask : '0;
  assign os_dirs_m   = os_dirs ? os_mask : '0;

  assign pins_we    = os_pins_m | side_pins_m;
  assign pins_wdata = (os_data & os_pins_m & ~side_pins_m) | (ss_data & side_pins_m);
  assign dirs_we    = os_dirs_m | side_dirs_m;
  assign dirs_wdata = (os_data & os_dirs_m & ~side_dirs_m) | (ss_data & side_dirs_m);

  // IRQ flags. IRQ (set) raises its flag on the first cycle only; IRQ WAIT
  // then stalls until the flag clears. WAIT 1 IRQ clears the flag it saw.
  assign irq_set = (active && is_irq && !irq_clr_bit && !irq_waiting) ? irq_bit : 8'd0;
  assign irq_clr = (done && ((is_irq && irq_clr_bit) ||
                             (is_wait && wait_src == 2'd2 && wait_pol))) ? irq_bit : 8'd0;

  // ---------------------------------------------------------------------------
  // Program counter control
  // ---------------------------------------------------------------------------

  logic       jump;
  logic [4:0] jump_addr;

  assign jump = done && ((is_jmp && jmp_cond) || (is_out && arg1 == OUT_PC) ||
                         (is_mov && arg1 == MOV_PC));
  assign jump_addr = is_jmp ? arg2 :
                     is_out ? out_data[4:0] : mov_val[4:0];
  // Only a completed instruction from instruction memory moves the PC on.
  // Wrap applies when that instruction is at WRAP_TOP and does not jump.
  always_comb begin
    if (jump) begin
      branch_en   = 1'b1;
      branch_addr = jump_addr;
    end else if (done && pc == wrap_top) begin
      branch_en   = 1'b1;
      branch_addr = wrap_bottom;
    end else if (done) begin
      branch_en   = 1'b0;
      branch_addr = pc + 5'd1;
    end else begin
      branch_en   = 1'b1;        // hold
      branch_addr = pc;
    end
  end

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  always_ff @(posedge clk) begin
    if (rst || restart) begin
      delay_cnt    <= '0;
      irq_waiting  <= 1'b0;
    end else begin
      // Delay starts after the instruction completes.
      if (done)
        delay_cnt <= delay;
      else if (ce && delay_cnt != 5'd0)
        delay_cnt <= delay_cnt - 5'd1;

      if (active && is_irq && !irq_clr_bit && irq_wait_bit)
        irq_waiting <= stall;
     end
    end
endmodule

`default_nettype wire
