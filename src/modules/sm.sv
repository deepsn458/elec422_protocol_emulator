// sm - one PIO state machine (RP2040 datasheet, chapter 3)
//
// Glue logic around the state machine's datapath blocks:
//   * isr      - input shift register  (IN, PUSH, autopush, MOV ISR, OUT ISR)
//   * osr      - output shift register (OUT, PULL, autopull, MOV OSR)
//   * regfile  - scratch registers X (reg 1) and Y (reg 2); reg 0 reads 0
//   * clockdiv - 16.8 fractional clock divider -> clock enable 'tick'
//
// The program counter and the instruction memory live outside this module:
//   * pc / instr: the PC register and the instruction stored at that address.
//   * branch_en / branch_addr: tell the PC what to load next. When branch_en
//     is low the PC increments (31 wraps to 0). branch_addr always holds the
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
// them). A forced instruction that stalls is retried on every clock,
// ignoring the clock divider and SM_ENABLE, until it completes.

`default_nettype none

module sm #(
  parameter logic [1:0] SM_ID = 2'd0      // state machine number, for IRQ rel
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

  // SMx_INSTR: instruction forced in by the host
  input  logic        force_valid,         // one-cycle write strobe
  input  logic [15:0] force_instr,
  output logic        exec_stalled,        // EXECCTRL.EXEC_STALLED

  // Program counter and instruction memory
  input  logic [4:0]  pc,                  // address of instr
  input  logic [15:0] instr,               // instruction memory[pc]
  output logic        branch_en,           // 1 = PC loads branch_addr
  output logic [4:0]  branch_addr,         // next PC

  // TX FIFO (host -> SM), first-word fall-through
  input  logic [31:0] tx_data,             // oldest word, valid when !tx_empty
  input  logic        tx_empty,
  input  logic [2:0]  tx_level,            // words held, 0..4 (MOV STATUS)
  output logic        tx_pop,

  // RX FIFO (SM -> host)
  output logic [31:0] rx_data,
  input  logic        rx_full,
  input  logic [2:0]  rx_level,
  output logic        rx_push,

  // GPIO: 32-bit write masks and data for pin levels and directions
  input  logic [31:0] gpio_in,
  output logic [31:0] pins_we,
  output logic [31:0] pins_wdata,
  output logic [31:0] dirs_we,
  output logic [31:0] dirs_wdata,

  // IRQ flags shared by all state machines
  input  logic [7:0]  irq_flags,
  output logic [7:0]  irq_set,
  output logic [7:0]  irq_clr
);

  localparam logic [5:0] FULL = 6'd32;

  // Opcodes
  localparam logic [2:0] OP_JMP  = 3'd0;
  localparam logic [2:0] OP_WAIT = 3'd1;
  localparam logic [2:0] OP_IN   = 3'd2;
  localparam logic [2:0] OP_OUT  = 3'd3;
  localparam logic [2:0] OP_PP   = 3'd4;   // PUSH (bit 7 = 0) / PULL (bit 7 = 1)
  localparam logic [2:0] OP_MOV  = 3'd5;
  localparam logic [2:0] OP_IRQ  = 3'd6;
  localparam logic [2:0] OP_SET  = 3'd7;

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

  // Low n bits set, n = 0..32 (1 << 32 is 0, so 0 - 1 gives all ones).
  function automatic logic [31:0] lowmask(input logic [5:0] n);
    return (32'h1 << n) - 32'h1;
  endfunction

  // Rotate left by s: maps bit 0 to GPIO s, wrapping after GPIO 31.
  function automatic logic [31:0] rotl(input logic [31:0] v, input logic [4:0] s);
    return (v << s) | (v >> (6'd32 - {1'b0, s}));
  endfunction

  // Rotate right by s: GPIO s becomes bit 0.
  function automatic logic [31:0] rotr(input logic [31:0] v, input logic [4:0] s);
    return (v >> s) | (v << (6'd32 - {1'b0, s}));
  endfunction

  function automatic logic [31:0] bitrev(input logic [31:0] v);
    logic [31:0] r;
    for (int i = 0; i < 32; i++)
      r[i] = v[31 - i];
    return r;
  endfunction

  // 5-bit count/threshold field: 0 encodes 32.
  function automatic logic [5:0] count32(input logic [4:0] n);
    return (n == 5'd0) ? FULL : {1'b0, n};
  endfunction

  // ---------------------------------------------------------------------------
  // Configuration fields
  // ---------------------------------------------------------------------------

  logic        side_en, side_pindir;
  logic [4:0]  jmp_pin, wrap_top, wrap_bottom;
  logic        status_sel;
  logic [3:0]  status_n;
  logic [5:0]  pull_thresh, push_thresh;
  logic        out_dir, in_dir, autopull, autopush;
  logic [2:0]  sideset_count, set_count;
  logic [5:0]  out_count;
  logic [4:0]  in_base, sideset_base, set_base, out_base;
  logic [15:0] div_int;
  logic [7:0]  div_frac;

  assign side_en       = execctrl[30];
  assign side_pindir   = execctrl[29];
  assign jmp_pin       = execctrl[28:24];
  assign wrap_top      = execctrl[16:12];
  assign wrap_bottom   = execctrl[11:7];
  assign status_sel    = execctrl[4];
  assign status_n      = execctrl[3:0];

  assign pull_thresh   = count32(shiftctrl[29:25]);
  assign push_thresh   = count32(shiftctrl[24:20]);
  assign out_dir       = shiftctrl[19];
  assign in_dir        = shiftctrl[18];
  assign autopull      = shiftctrl[17];
  assign autopush      = shiftctrl[16];

  assign sideset_count = (pinctrl[31:29] > 3'd5) ? 3'd5 : pinctrl[31:29];
  assign set_count     = (pinctrl[28:26] > 3'd5) ? 3'd5 : pinctrl[28:26];
  assign out_count     = (pinctrl[25:20] > FULL) ? FULL : pinctrl[25:20];
  assign in_base       = pinctrl[19:15];
  assign sideset_base  = pinctrl[14:10];
  assign set_base      = pinctrl[9:5];
  assign out_base      = pinctrl[4:0];

  assign div_int       = clkdiv[31:16];
  assign div_frac      = clkdiv[15:8];

  // Instruction fields (decoded below; arg2 is also the IN/OUT bit count)
  logic [2:0] op, arg1;
  logic [4:0] dss, arg2;

  // ---------------------------------------------------------------------------
  // Submodules
  // ---------------------------------------------------------------------------

  logic        tick;

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
  logic [31:0] xy_wdata;
  logic [31:0] x, y;

  regfile #(
    .REG_WIDTH (32),
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
  logic [5:0]  isr_load_cnt;
  logic [31:0] isr_din;
  logic [31:0] isr_q, isr_shift_q;
  logic [5:0]  isr_cnt, isr_shift_cnt;

  isr u_isr (
    .clk       (clk),
    .rst       (rst | restart | isr_clear),
    .ce        (1'b1),
    .load      (isr_load),
    .load_cnt  (isr_load_cnt),
    .shift     (isr_shift),
    .n         (arg2),
    .dir       (in_dir),
    .din       (isr_din),
    .q         (isr_q),
    .cnt       (isr_cnt),
    .shift_q   (isr_shift_q),
    .shift_cnt (isr_shift_cnt)
  );

  logic        osr_load, osr_shift;
  logic [31:0] osr_din;
  logic [31:0] osr_q, out_data;
  logic [5:0]  osr_cnt, osr_shift_cnt;

  osr u_osr (
    .clk       (clk),
    .rst       (rst | restart),
    .ce        (1'b1),
    .load      (osr_load),
    .shift     (osr_shift),
    .n         (arg2),
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
  logic        exec_pending;   // run exec_latch instead of instruction memory
  logic        exec_forced;    // exec_latch holds a stalled SMx_INSTR write
  logic [15:0] exec_latch;     // OUT EXEC / MOV EXEC / stalled forced instr
  logic        irq_waiting;    // IRQ WAIT has set its flag, waiting for clear

  logic        ce;             // program execution enable for this cycle
  logic        run_latched;    // retry a stalled forced instruction
  logic        run_prog;       // run from exec latch or instruction memory
  logic        forced;         // instruction comes from SMx_INSTR
  logic        from_imem;      // instruction comes from instruction memory
  logic        active;         // an instruction is executing this cycle
  logic        stall;          // ...but cannot complete
  logic        done;           // ...and completes

  assign ce          = en & tick;
  assign run_latched = !force_valid && exec_pending && exec_forced;
  assign run_prog    = !force_valid && !run_latched && ce && (delay_cnt == 5'd0);
  assign forced      = force_valid || run_latched;
  assign from_imem   = run_prog && !exec_pending;
  assign active      = forced || run_prog;
  assign done        = active && !stall;

  logic [15:0] ins;
  assign ins = force_valid  ? force_instr :
               exec_pending ? exec_latch  : instr;

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
  logic [5:0] bit_count;         // IN/OUT bit count, 1..32

  assign op   = ins[15:13];
  assign dss  = ins[12:8];
  assign arg1 = ins[7:5];
  assign arg2 = ins[4:0];

  assign is_jmp  = (op == OP_JMP);
  assign is_wait = (op == OP_WAIT);
  assign is_in   = (op == OP_IN);
  assign is_out  = (op == OP_OUT);
  assign is_push = (op == OP_PP) && !ins[7];
  assign is_pull = (op == OP_PP) &&  ins[7];
  assign is_mov  = (op == OP_MOV);
  assign is_irq  = (op == OP_IRQ);
  assign is_set  = (op == OP_SET);

  assign if_flag      = ins[6];
  assign blk          = ins[5];
  assign irq_clr_bit  = ins[6];
  assign irq_wait_bit = ins[5];
  assign mov_op       = ins[4:3];
  assign mov_srcsel   = ins[2:0];
  assign wait_src     = ins[6:5];
  assign wait_pol     = ins[7];
  assign bit_count    = count32(arg2);

  // Delay/side-set split: the top sideset_count bits are side-set, the rest
  // delay. With SIDE_EN the top side-set bit is an enable.
  logic [4:0]  delay;
  logic [4:0]  ss_field;         // side-set bits, right-aligned
  logic        ss_valid;
  logic [2:0]  ss_bits;          // side-set data bits, 0..5
  logic [31:0] ss_mask, ss_data;

  assign delay    = dss & (5'h1F >> sideset_count);
  assign ss_field = dss >> (3'd5 - sideset_count);
  assign ss_valid = (sideset_count != 3'd0) &&
                    (!side_en || ss_field[sideset_count - 3'd1]);
  assign ss_bits  = (side_en && sideset_count != 3'd0) ? sideset_count - 3'd1
                                                       : sideset_count;
  assign ss_mask  = rotl(lowmask({3'd0, ss_bits}), sideset_base);
  assign ss_data  = rotl({27'd0, ss_field} & lowmask({3'd0, ss_bits}), sideset_base) & ss_mask;

  // IRQ index: bit 4 = rel, which adds SM_ID to bits 1:0 (modulo 4).
  logic [2:0] irq_idx;
  logic [7:0] irq_bit;

  assign irq_idx = arg2[4] ? {arg2[2], arg2[1:0] + SM_ID} : arg2[2:0];
  assign irq_bit = 8'd1 << irq_idx;

  // ---------------------------------------------------------------------------
  // Operands
  // ---------------------------------------------------------------------------

  logic [31:0] in_pins;          // GPIOs rotated so IN_BASE is bit 0
  logic [31:0] status;
  logic [31:0] in_src, mov_src, mov_val;

  assign in_pins = rotr(gpio_in, in_base);
  assign status  = ({1'b0, (status_sel ? rx_level : tx_level)} < status_n) ? 32'hFFFF_FFFF : 32'd0;

  always_comb begin
    case (arg1)                  // IN source
      3'd0:    in_src = in_pins;
      3'd1:    in_src = x;
      3'd2:    in_src = y;
      3'd6:    in_src = isr_q;
      3'd7:    in_src = osr_q;
      default: in_src = 32'd0;   // NULL, reserved
    endcase

    case (mov_srcsel)
      3'd0:    mov_src = in_pins;
      3'd1:    mov_src = x;
      3'd2:    mov_src = y;
      3'd5:    mov_src = status;
      3'd6:    mov_src = isr_q;
      3'd7:    mov_src = osr_q;
      default: mov_src = 32'd0;  // NULL, reserved
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
    x_nz_q <= (x != 32'd0);
    y_nz_q <= (y != 32'd0);
  end

  logic jmp_cond;
  always_comb begin
    case (arg1)
      3'd0:    jmp_cond = 1'b1;                     // always
      3'd1:    jmp_cond = (x == 32'd0);             // !X
      3'd2:    jmp_cond = x_nz_q;                   // X--
      3'd3:    jmp_cond = (y == 32'd0);             // !Y
      3'd4:    jmp_cond = y_nz_q;                   // Y--
      3'd5:    jmp_cond = (x != y);                 // X!=Y
      3'd6:    jmp_cond = gpio_in[jmp_pin];         // PIN
      default: jmp_cond = (osr_cnt < pull_thresh);  // !OSRE
    endcase
  end

  logic wait_bit;
  always_comb begin
    case (wait_src)
      2'd0:    wait_bit = gpio_in[arg2];
      2'd1:    wait_bit = in_pins[arg2];
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
  assign isr_load_cnt = is_out ? bit_count : 6'd0;
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
    xy_wdata = 32'd0;
    if (done) begin
      if (is_jmp && arg1 == 3'd2) begin                        // X--
        xy_we = 1'b1;  xy_addr = 2'd1;  xy_wdata = x - 32'd1;
      end else if (is_jmp && arg1 == 3'd4) begin               // Y--
        xy_we = 1'b1;  xy_addr = 2'd2;  xy_wdata = y - 32'd1;
      end else if ((is_out || is_mov || is_set) && (arg1 == 3'd1 || arg1 == 3'd2)) begin
        xy_we    = 1'b1;
        xy_addr  = (arg1 == 3'd1) ? 2'd1 : 2'd2;
        xy_wdata = is_out ? out_data :
                   is_mov ? mov_val  : {27'd0, arg2};
      end
    end
  end

  // Pins. OUT and MOV use the OUT mapping, SET the SET mapping. Side-set
  // happens on every active cycle, stalled or not, and wins on overlap.
  logic        os_pins, os_dirs;
  logic [31:0] os_raw, os_mask, os_data;
  logic [31:0] side_pins_m, side_dirs_m, os_pins_m, os_dirs_m;

  assign os_pins = done && ((is_out && arg1 == OUT_PINS) || (is_mov && arg1 == MOV_PINS) ||
                            (is_set && arg1 == SET_PINS));
  assign os_dirs = done && ((is_out && arg1 == OUT_PINDIRS) || (is_set && arg1 == SET_PINDIRS));
  assign os_raw  = is_set ? {27'd0, arg2} :
                   is_out ? out_data : mov_val;
  assign os_mask = rotl(lowmask(is_set ? {3'd0, set_count} : out_count),
                        is_set ? set_base : out_base);
  assign os_data = rotl(os_raw, is_set ? set_base : out_base) & os_mask;

  assign side_pins_m = (active && ss_valid && !side_pindir) ? ss_mask : 32'd0;
  assign side_dirs_m = (active && ss_valid &&  side_pindir) ? ss_mask : 32'd0;
  assign os_pins_m   = os_pins ? os_mask : 32'd0;
  assign os_dirs_m   = os_dirs ? os_mask : 32'd0;

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
  logic       exec_set;          // OUT EXEC / MOV EXEC

  assign jump = done && ((is_jmp && jmp_cond) || (is_out && arg1 == OUT_PC) ||
                         (is_mov && arg1 == MOV_PC));
  assign jump_addr = is_jmp ? arg2 :
                     is_out ? out_data[4:0] : mov_val[4:0];
  assign exec_set  = done && ((is_out && arg1 == OUT_EXEC) || (is_mov && arg1 == MOV_EXEC));

  // Only a completed instruction from instruction memory moves the PC on.
  // Wrap applies when that instruction is at WRAP_TOP and does not jump.
  always_comb begin
    if (jump) begin
      branch_en   = 1'b1;
      branch_addr = jump_addr;
    end else if (done && from_imem && pc == wrap_top) begin
      branch_en   = 1'b1;
      branch_addr = wrap_bottom;
    end else if (done && from_imem) begin
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

  assign exec_stalled = exec_pending && exec_forced;

  always_ff @(posedge clk) begin
    if (rst || restart) begin
      delay_cnt    <= '0;
      irq_waiting  <= 1'b0;
      exec_pending <= 1'b0;
      exec_forced  <= 1'b0;
      exec_latch   <= '0;
    end else begin
      // Delay starts after the instruction completes. Forced instructions
      // and OUT/MOV EXEC ignore their delay field.
      if (done && !forced && !exec_set)
        delay_cnt <= delay;
      else if (ce && delay_cnt != 5'd0)
        delay_cnt <= delay_cnt - 5'd1;

      if (active && is_irq && !irq_clr_bit && irq_wait_bit)
        irq_waiting <= stall;

      if (exec_set) begin
        exec_latch   <= is_out ? out_data[15:0] : mov_val[15:0];
        exec_pending <= 1'b1;
        exec_forced  <= 1'b0;
      end else if (force_valid && stall) begin
        exec_latch   <= force_instr;
        exec_pending <= 1'b1;
        exec_forced  <= 1'b1;
      end else if (exec_pending && !force_valid && done) begin
        exec_pending <= 1'b0;
        exec_forced  <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
