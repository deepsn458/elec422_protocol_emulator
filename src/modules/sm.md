# sm.sv: how the PIO state machine works

`sm.sv` is one PIO state machine, modelled on chapter 3 of the RP2040 datasheet. It decodes a 16-bit instruction and decides whether that instruction can finish this cycle. It then drives the blocks that do the work:

| Instance | Module | Job |
|---|---|---|
| `u_decode` | `decode.sv` | Splits the instruction into fields, delay/side-set and IRQ index |
| `u_clockdiv` | `clockdiv.sv` | Makes `tick`, the clock enable that sets the SM's speed |
| `u_xy` | `regfile.sv` | Scratch registers X (reg 1) and Y (reg 2) |
| `u_isr` | `isr.sv` | Input shift register (IN, PUSH, autopush) |
| `u_osr` | `osr.sv` | Output shift register (OUT, PULL, autopull) |

Everything shared between state machines stays **outside** `sm.sv` and connects through ports. That covers the instruction memory, the TX/RX FIFOs, the GPIO output registers and the IRQ flags.

```
 host regs ──► ┌──────────────────── sm ────────────────────┐ ◄─► TX / RX FIFO
               │ decode  clockdiv  regfile(X,Y)  isr  osr   │
 PC ◄────────► │      decode + control (active/stall/done) │ ◄─► IRQ flags
 imem ───────► │      pin mapping + side-set               │ ──► GPIO regs
               └────────────────────────────────────────────┘
```

The file is organised in the order below; each heading matches a `// ---` section in the code.

---

## 1. Ports

| Group | Ports | Notes |
|---|---|---|
| Clock/reset | `clk`, `rst` | `rst` is synchronous, active high |
| CTRL register | `en`, `restart`, `clkdiv_restart` | `restart` and `clkdiv_restart` are one-cycle pulses |
| Config registers | `clkdiv`, `execctrl`, `shiftctrl`, `pinctrl` | 32 bits each, **RP2040 bit layout** |
| SMx_INSTR | `force_valid`, `force_instr`, `exec_stalled` | Host-forced instruction |
| Instruction memory | `mem_addr`, `read_en` out; `instr` in | See section 9 |
| TX FIFO | `tx_data`, `tx_empty`, `tx_level` in; `tx_pop` out | `tx_data` must be valid *before* the pop (first-word fall-through) |
| RX FIFO | `rx_full`, `rx_level` in; `rx_data`, `rx_push` out | |
| GPIO | `gpio_in` in; `pins_we/wdata`, `dirs_we/wdata` out | Write masks + data, one bit per GPIO |
| IRQ | `irq_flags` in; `irq_set`, `irq_clr` out | One-hot requests to the shared flag register |

The parameter `SM_ID` (0..3) is only used for relative IRQ numbers.

## 2. Helpers

Small functions used throughout:

- `lowmask(n)`: the low `n` bits set, for `n` = 0..32. It works for 32 because `1 << 32` is 0 in a 32-bit expression, and `0 - 1` = all ones.
- `rotl(v, s)` and `rotr(v, s)`: 32-bit rotates. Pin ranges wrap after GPIO 31, so mapping data onto pins is a rotate, not a shift.
- `bitrev(v)`: bit reversal, for `mov x, ::y`.
- `count32(n)`: 5-bit count fields encode 32 as 0.

## 3. Configuration fields

These are plain `assign`s that slice the config registers into named fields (`wrap_top`, `pull_thresh`, `out_base`, ...). The thresholds go through `count32`, so `pull_thresh` / `push_thresh` are 6-bit values in the range 1..32. The counts are clamped: SET and side-set to at most 5, OUT to at most 32.

## 4. Submodules

**decode**: purely combinational. Section 6 describes it.

**clockdiv**: `tick` is high for one cycle every `INT + FRAC/256` cycles on average. The SM only runs program instructions when `ce = en & tick`. The clock itself is never divided. `clkdiv_restart` resets the divider so it ticks on the next cycle.

**regfile (X, Y)**: instantiated with `NUMREGS = 3`, and register 0 is the hardwired zero. The two read ports are tied permanently to X (`src_reg_1 = 1`) and Y (`src_reg_2 = 2`). JMP X!=Y needs both at once, so `x` and `y` are always available. One write port (`xy_we`, `xy_addr`, `xy_wdata`) is enough, because no instruction writes both. **The regfile writes on the falling clock edge**; see section 7 for why this matters.

**isr**: `n` is the instruction's bit-count field (`arg2`), and `dir` is IN_SHIFTDIR. `ce` is tied to 1 because the SM gates the `load`/`shift` strobes itself. The isr's synchronous `rst` is driven by `rst | restart | isr_clear`. That reset is also how PUSH and autopush clear the ISR (section 8).

**osr**: `n` = `arg2`, `dir` = OUT_SHIFTDIR. `shifted` (the bits leaving, right-aligned) is called `out_data` in `sm`. That is what OUT writes to its destination.

## 5. Instruction source and execution enable

Every cycle, `sm` answers three questions.

**Which instruction?** In priority order:

```systemverilog
assign ins = force_valid  ? force_instr :   // host wrote SMx_INSTR this cycle
             exec_pending ? exec_latch  :   // from OUT EXEC / MOV EXEC, or a stalled forced instr
                            instr;          // normal: instruction memory at pc
```

**Does it run this cycle (`active`)?**

| Signal | Meaning |
|---|---|
| `ce = en & tick` | The program may run: SM enabled and the divider ticked |
| `run_latched` | A forced instruction stalled earlier and is retried. It ignores `en` and the divider |
| `run_prog` | Normal execution: `ce` high, no delay cycles left, nothing forced |
| `forced` | The instruction came from the host (new or retried) |
| `from_imem` | The instruction came from instruction memory. **Only these move the PC on** |
| `active = forced \| run_prog` | Something executes this cycle |

**Can it finish (`stall`)?** This comes from section 7. Then:

```systemverilog
assign done = active && !stall;
```

Almost every side effect (register writes, shifts, pin writes, FIFO pushes) is gated by `done`. A stalled instruction does nothing except side-set, and it runs again on the next enabled cycle because the PC holds.

## 6. Decode (`decode.sv`)

`sm` instantiates `decode` (as `u_decode`) on the selected instruction `ins`. Its inputs are only `ins`, SIDESET_COUNT, SIDE_EN and the `SM_ID` parameter. All of its outputs are combinational. The instruction word splits into four fields:

```
 15  13 12      8 7    5 4      0
[ op  ][ dss    ][ arg1 ][ arg2  ]
         delay /   dest/    count/
         side-set  cond/src addr/data
```

`decode` outputs `arg1`, `arg2` and `bit_count` (`arg2` with 0 meaning 32). The `is_jmp` ... `is_set` signals come from `op`. PUSH and PULL share opcode 4 and differ in bit 7. Named bits (`blk`, `if_flag`, `irq_clr_bit`, `wait_pol`, ...) are pulled out with `assign`s, so the `always_comb` blocks never use bit-selects. Icarus prints "sorry" notices for bit-selects inside `always_comb`.

### Delay vs side-set

The 5-bit `dss` field is shared. The top `SIDESET_COUNT` bits are side-set and the rest are delay:

```systemverilog
assign delay    = dss & (5'h1F >> sideset_count);   // low (5 - count) bits
assign ss_field = dss >> (3'd5 - sideset_count);    // high count bits, right-aligned
```

With `SIDE_EN` = 1, the top side-set bit is an **enable**, so one fewer bit is data. `decode` outputs:
- `ss_valid`: whether this instruction side-sets;
- `ss_bits`: how many data bits there are;
- `ss_value`: the data bits, right-aligned.

Mapping onto GPIOs stays in `sm`, next to the rest of the pin logic:

```systemverilog
assign ss_mask = rotl(lowmask({3'd0, ss_bits}), sideset_base);
assign ss_data = rotl({27'd0, ss_value}, sideset_base) & ss_mask;
```

Example: `.side_set 1 opt` gives SIDESET_COUNT = 2 and SIDE_EN = 1. Take `pull side 1 [7]` = `0x9FA0`, where `dss = 11111`:
- `ss_field = 11`: the enable bit is 1 and the data bit is 1, so the side-set pin is driven high.
- `delay = 111` = 7 cycles.

### IRQ index

```systemverilog
assign irq_idx = arg2[4] ? {arg2[2], arg2[1:0] + SM_ID} : arg2[2:0];
```

If bit 4 (`rel`) is set, `SM_ID` is added to the low two bits, modulo 4. For example, on SM 1, `irq set 0x16` (rel, index 6) sets flag `{1, (2+1)%4}` = 7.

## 7. Operands, conditions and stalls

### Operands

- `in_pins = rotr(gpio_in, in_base)` puts GPIO `IN_BASE` at bit 0. IN PINS, MOV PINS and WAIT PIN all use it.
- `in_src`: the IN source (PINS, X, Y, NULL, ISR or OSR).
- `mov_src`: the MOV source (adds STATUS). `mov_val` is `mov_src` after the MOV operation: none, invert (`~`) or bit-reverse.
- `status` is all ones when the TX level (or the RX level, if `STATUS_SEL` = 1) is less than `STATUS_N`.

### JMP conditions

| `arg1` | Condition | Test |
|---|---|---|
| 0 | always | 1 |
| 1 | `!x` | `x == 0` |
| 2 | `x--` | `x_nz_q` (X was nonzero **before** the decrement) |
| 3 | `!y` | `y == 0` |
| 4 | `y--` | `y_nz_q` |
| 5 | `x!=y` | `x != y` |
| 6 | `pin` | `gpio_in[JMP_PIN]` |
| 7 | `!osre` | `osr_cnt < pull_thresh` |

**Why `x_nz_q` exists.** `jmp x--` must branch on the *old* X and also write X−1. The regfile writes at the **falling** edge, so by the next rising edge (when the PC samples `branch_addr`), `x` already shows the new value. A test written as `x != 0` would therefore use the wrong value. `x_nz_q` is a flop clocked on the same falling edge. Nonblocking assignment means it captures `x != 0` **before** the write lands:

```
cycle:       |---- jmp x-- ----|
clk:         ‾‾‾‾‾‾‾‾\________/‾‾‾
x:           1       |  0              <- regfile writes x-1 at the falling edge
x_nz_q:      ?       |  1              <- sampled from the old x at the same edge
branch:                       ^ PC samples here: taken (x was 1)
```

If the regfile is ever changed to write on the rising edge, delete `x_nz_q`/`y_nz_q` and use `x != 0` / `y != 0`.

### Stall conditions

| Instruction | Stalls when |
|---|---|
| WAIT | The selected GPIO / pin / IRQ flag is not equal to the polarity |
| IN | Autopush is on, this IN reaches the threshold (`isr_shift_cnt >= push_thresh`), and the RX FIFO is full |
| OUT | Autopull is on and the OSR is already empty (`osr_cnt >= pull_thresh`) |
| PUSH block | RX FIFO full (unless IFFULL says skip) |
| PULL block | TX FIFO empty (unless IFEMPTY or autopull says skip) |
| IRQ wait | Always on the first cycle (the flag is being set), then while the flag is still set |
| JMP, MOV, SET | Never |

The helper signals make these readable:

- `in_push`: this IN triggers an autopush.
- `out_empty`: an OUT finds the OSR already empty (it must wait for a refill).
- `out_refill`: this OUT empties the OSR and the FIFO has data, so refill now.
- `push_skip` / `pull_skip`: a conditional PUSH or PULL is a no-op. With autopull on, PULL is a no-op while the OSR still has data, as the datasheet says.

## 8. Datapath control

### ISR

| Strobe | When |
|---|---|
| `isr_shift` | A completed IN that does **not** autopush |
| `isr_clear` (to isr `rst`) | IN with autopush, or a PUSH that is not skipped |
| `isr_load` | MOV ISR (count 0) or OUT ISR (count = bit count) |
| `rx_push` | IN with autopush, or a PUSH that is not skipped, if the FIFO is not full |

`rx_data` is `isr_shift_q` for an autopush and `isr_q` for a PUSH.

**Why clear through `rst`.** An autopush pushes the *shifted* value (`isr_shift_q`, which needs `din` = the IN source) and empties the ISR in the same cycle. Using `load` with `din = 0` would conflict with the shift. The isr's synchronous reset sets `q = 0, cnt = 0` without touching `din`, so it works as a clear. This needed no change to `isr.sv`.

Example: with IN_SHIFTDIR = left, `in pins, 4` twice with pin values 5 then A gives ISR = `0x5A` with count 8. A `push` then sends `0x5A` and the ISR goes back to 0.

### OSR

`osr_shift` = a completed OUT. `osr_load` happens for one of these reasons:

| Reason | Data | Signal |
|---|---|---|
| OUT stalled on an empty OSR, FIFO has data | `tx_data` | part of `tx_pop` |
| This OUT empties the OSR, FIFO has data | `tx_data` | `out_refill` |
| PULL | `tx_data` | `pull_fifo` |
| PULL noblock on an empty FIFO | `x` | `pull_x` |
| MOV OSR | `mov_val` | `mov_osr` |
| Background autopull: any other enabled cycle with an empty OSR | `tx_data` | `bg_refill` |

`tx_pop` is the OR of every case that takes data from the FIFO. When an OUT and a refill happen together, `osr.sv`'s rule (load beats shift) makes the new word win. `out_data` was already computed from the old contents.

Example (datasheet figure 44): `out x, 32` / `in x, 32` with autopull and autopush:

```
cycle:   0          1           2         3           4
instr:   out(stall) out         in        out         in
tx_pop:  1          1           0         1           0
rx_push: 0          0           1         0           1
```

Cycle 0 fills the empty OSR. From then on each OUT refills in the same cycle, and each IN pushes straight to the RX FIFO.

### Scratch registers

There is one write per cycle, gated by `done`:

| Instruction | Writes |
|---|---|
| `jmp x--` / `jmp y--` | `x - 1` / `y - 1` (always, taken or not) |
| `out x/y, n` | `out_data` |
| `mov x/y, src` | `mov_val` |
| `set x/y, data` | `{27'b0, data}` |

### Pins

OUT and MOV write to the **OUT** range (OUT_BASE, OUT_COUNT); SET writes to the **SET** range. Both build a mask and data the same way:

```systemverilog
os_mask = rotl(lowmask(count), base);
os_data = rotl(value, base) & os_mask;
```

Side-set uses its own range and is gated by `active`, **not** `done`, so it still happens when the instruction stalls. Where side-set and OUT/SET hit the same pin, side-set wins:

```systemverilog
pins_wdata = (os_data & os_pins_m & ~side_pins_m) | (ss_data & side_pins_m);
```

Example: OUT_BASE = 16 and OUT_COUNT = 8. `mov pins, x` gives `pins_we = 0x00FF0000`, and only GPIO 16..23 change.

The SM does **not** store pin values. The top level keeps the output registers and applies the masks (and merges several SMs):

```systemverilog
gpio_out <= (gpio_out & ~pins_we) | (pins_wdata & pins_we);
```

### IRQ

- `irq_set` comes from IRQ (set or wait). It fires **only while `irq_waiting` is 0**, so an IRQ WAIT sets its flag once and doesn't keep re-setting it while waiting.
- `irq_clr` comes from `irq clear` and from `wait 1 irq n` when it completes.

## 9. Program counter control

The PC is `program_counter.sv`, instantiated inside `sm` as `u_pc` (5-bit address, increment 1). Its `pc` drives `mem_addr`, and its `read_en` goes straight out. `sm` tells it what to do next through the internal `branch_en`/`branch_addr`:

| This cycle | `branch_en` | `branch_addr` |
|---|---|---|
| Completed JMP (condition true), OUT PC or MOV PC | 1 | target |
| Completed instruction from memory, at `WRAP_TOP`, no jump | 1 | `WRAP_BOTTOM` |
| Completed instruction from memory, otherwise | 0 | `pc + 1` |
| Anything else: stalled, delay cycle, no tick, disabled, EXEC'd or forced instruction | 1 | `pc` (hold) |

Holding works by "branching to the current address", so the PC only needs a load and an increment. `branch_addr` is **always** the next PC, which also makes it a good address for a synchronous-read instruction memory.

`pc_en` is tied high, since holds are done with branches. `rst_n` is `!rst`; note the PC's reset is asynchronous while the rest of `sm` resets synchronously.

## 10. State registers

The `always_ff @(posedge clk)` block holds the SM's own state:

- **`delay_cnt`** loads the instruction's delay when it completes, then counts down on each `ce`. While it is nonzero, `run_prog` is 0. Delay starts only after a stall ends, because it loads on `done`. Forced instructions and OUT/MOV EXEC ignore their own delay.
- **`irq_waiting`** is set on the first cycle of `irq wait` and cleared when the instruction completes.
- **`exec_latch` / `exec_pending` / `exec_forced`**:
  - OUT EXEC or MOV EXEC stores the instruction, which runs next cycle with the PC held.
  - A forced instruction that stalls is stored with `exec_forced = 1` (shown on `exec_stalled`) and retried every clock until it completes.
  - The latch is cleared when the latched instruction completes.
- **`rst` / `restart`** clear all of the above. `restart` also clears the ISR and resets the OSR count to 32, but keeps X, Y and the PC.

Example (OUT EXEC): `pull`, then `out exec, 16 [3]`, where the TX word is `0xE227` (`set x, 7 [2]`):

```
cycle 0  pull
cycle 1  out exec, 16     pc -> 2, latch = set x,7 [2]   (its [3] delay is ignored)
cycle 2  set x, 7         from the latch, pc stays 2
cycle 3  (delay)
cycle 4  (delay)
cycle 5  instruction at pc 2
```

## 11. Differences from the RP2040

- OUT_STICKY, INLINE_OUT_EN / OUT_EN_SEL and FJOIN are not implemented. FJOIN belongs on the FIFO side anyway.
- `restart` also zeroes the OSR contents, because `osr.sv` has no "reset the count only" input.
- Reserved encodings (MOV destination 3, WAIT source 3, unused SET destinations) do nothing.
- A PUSH noblock to a full FIFO drops the data with no debug flag.

## 12. Things to know when integrating

- **FIFO:** `tx_data` must show the oldest word while `tx_empty` is 0. The current `fifo.sv` outputs data one cycle *after* `r_en` and keeps `full`/`empty` internal. It needs a fall-through output plus `full`, `empty` and level ports.
- **Timing:** the regfile's write path has half a clock period (rising edge to falling edge). Testbench inputs should change just after the rising edge, not at the falling edge.
- **X and Y have no reset.** Programs (or the host, through forced instructions) must initialise them.
- **Tests:** run `make sim_tb_sm` from `test/`. `test/modules/tb_sm.sv` runs 17 groups of small PIO programs against this module.
