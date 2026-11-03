# sm.sv: how the PIO state machine works

`sm.sv` is one PIO state machine, modelled on chapter 3 of the RP2040 datasheet. It decodes a 16-bit instruction and decides whether that instruction can finish this cycle. It then drives the blocks that do the work:

| Instance | Module | Job |
|---|---|---|
| `u_decode` | `decode.sv` | Splits the instruction into fields, delay/side-set and IRQ index |
| `u_clockdiv` | `clockdiv.sv` | Makes `tick`, the clock enable that sets the SM's speed |
| `u_xy` | `regfile.sv` | Scratch registers X (reg 1) and Y (reg 2) |
| `u_isr` | `isr.sv` | Input shift register (IN, PUSH, autopush) |
| `u_osr` | `osr.sv` | Output shift register (OUT, PULL, autopull) |
| `u_pc` | `program_counter.sv` | The program counter |

Everything shared between state machines stays **outside** `sm.sv` and connects through ports. That covers the instruction memory, the TX/RX FIFOs, the GPIO output registers and the IRQ flags.

```
 host regs ──► ┌──────────────────── sm ────────────────────┐ ◄─► TX / RX FIFO
               │ decode clockdiv regfile(X,Y) isr osr pc    │
 imem ◄──────► │      decode + control (active/stall/done) │ ◄─► IRQ flags
               │      pin mapping + side-set               │ ──► GPIO regs
               └────────────────────────────────────────────┘
```

---

## 0. The big picture

Read this first if the rest feels like a pile of signals. The PIO state machine is a **very small CPU** whose only job is reading and driving pins with exact timing. It has:

- a short program (up to 32 instructions) in instruction memory;
- two variables, **X** and **Y** (the scratch registers);
- two shift registers: the **OSR** holds bits waiting to go out, the **ISR** collects bits coming in;
- two queues to the host processor: the **TX FIFO** (host → SM) and the **RX FIFO** (SM → host).

Every cycle it does four things, and every signal in `sm.sv` is part of one of them:

1. The PC says which instruction to run.
2. Read that instruction from memory.
3. Do it: set a pin, shift a bit, jump, wait for something.
4. Move the PC (next address, or a jump target).

There are only 9 instructions:

| Instruction | Plain meaning |
|---|---|
| `set` | Put a small constant (0..31) on pins or into X/Y |
| `out` | Take bits from the OSR and send them somewhere (usually pins) |
| `in` | Take bits from somewhere (usually pins) into the ISR |
| `pull` | Refill the OSR from the TX FIFO |
| `push` | Send the ISR to the RX FIFO |
| `mov` | Copy a 32-bit value from one place to another |
| `jmp` | Go to another instruction, maybe only if a condition holds |
| `wait` | Pause until a pin or flag has a value |
| `irq` | Set or clear a flag, to signal the host or another SM |

A whole serial transmitter, start to finish:

```
    pull            ; get a word from the TX FIFO into the OSR
    set x, 7        ; count 8 bits
bit:
    out pins, 1     ; put one bit on the pin
    jmp x--, bit    ; repeat until all 8 bits are sent
```

Wrap then brings it back to `pull` for the next word. Everything else in this document (config registers, side-set, delay, stall/done, forced instructions) is detail on top of this.

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
| GPIO | `gpio_in` in; `pins_we/wdata`, `dirs_we/wdata` out | Write masks + data, one bit per GPIO; `NUM_GPIO` bits wide |
| IRQ | `irq_flags` in; `irq_set`, `irq_clr` out | One-hot requests to the shared flag register |

Parameters:

- `SM_ID` (0..3) is only used for relative IRQ numbers.
- `NUM_GPIO` (2, 4, 8, 16 or 32; default 32) is the number of GPIOs. See "GPIO count" below. Any other value stops elaboration with an error.

### Program side vs host side

The ports fall into two groups:

- **Program side**, used while the program runs: instruction memory, FIFOs, GPIOs, IRQ flags.
- **Host side**, used by the host (the CPU, or whatever loads programs) to set the SM up and control it: CTRL, the config registers and SMx_INSTR.

The host side is needed because a program can't configure itself: pin mapping, shift direction, autopull thresholds and clock speed change how its instructions behave, so something outside the SM must supply them. The FIFOs carry *data*; instruction memory carries the *program*; the host-side ports carry *settings and control*.

On the RP2040 this is the register map in datasheet section 3.7. The host-side ports are a one-to-one copy of those registers:

| RP2040 register | `sm` ports |
|---|---|
| `CTRL` | `en`, `restart`, `clkdiv_restart` |
| `SMx_CLKDIV` | `clkdiv` |
| `SMx_EXECCTRL` | `execctrl` (and `exec_stalled` back) |
| `SMx_SHIFTCTRL` | `shiftctrl` |
| `SMx_PINCTRL` | `pinctrl` |
| `SMx_INSTR` | `force_valid`, `force_instr` |
| `INSTR_MEM0..31` | instruction memory (outside `sm`) |
| `TXF`/`RXF`/`FSTAT` | the FIFOs (outside `sm`) |
| `IRQ`/`IRQ_FORCE` | the IRQ flag register (outside `sm`) |

On the RP2040 the bus connects to the PIO *block*, which holds these registers and wires them into each SM. Our top level does the same thing.

**These ports are not chip pins.** They connect to registers inside the chip. With a small pin budget (for example 8 in / 8 out / 8 bidir), the host fills those registers through a narrow interface such as an SPI slave (about 4 pins): the host sends an address and data, and the address selects instruction memory word *n*, PINCTRL, the TX FIFO, and so on. The rest of the pins become SM GPIOs.

### GPIO count (`NUM_GPIO`)

The RP2040 has 32 GPIOs; a small chip has far fewer real pins (with 8 bidir pads, the SM realistically gets 8). Set `NUM_GPIO` to match, e.g. `sm #(.NUM_GPIO(8))`. The 8 bidir pads fit naturally: `gpio_out` drives the pad, `gpio_oe` (from `dirs_wdata`) is its output enable, and the pad's input goes to `gpio_in`.

Why not keep 32 and connect only the low 8 bits? It would work, but:

1. **Area.** The pin mapping rotates by a base chosen at runtime. With 32-wide rotates, each of the 8 used output bits is still a 32-to-1 mux over the data bits, because any base could put any data bit there; synthesis can't remove it. An 8-wide rotate is an 8-to-1 mux per bit, about 4x smaller, for OUT, SET, side-set and IN.
2. **Wrap.** Pin ranges should wrap at the last real GPIO. With 32-wide rotates, `OUT_BASE = 6, OUT_COUNT = 4` hits GPIO 6, 7, 8, 9, and 8 and 9 don't exist. With `NUM_GPIO = 8` they wrap to GPIO 0 and 1, like the RP2040 wraps at GPIO 31.

What changes with `NUM_GPIO`:

| Item | Behaviour |
|---|---|
| GPIO ports | `NUM_GPIO` bits wide |
| Pin ranges (OUT/MOV pins, SET, side-set, IN) | Rotate modulo `NUM_GPIO`, so they wrap at GPIO `NUM_GPIO-1` |
| GPIO-number fields: `IN_BASE`, `SIDESET_BASE`, `SET_BASE`, `OUT_BASE`, `JMP_PIN`, the WAIT GPIO/PIN index | Only the low `$clog2(NUM_GPIO)` bits are used, i.e. taken modulo `NUM_GPIO`. With 8 GPIOs, `SET_BASE = 14` is the same as 6 |
| Counts | Masks saturate at `NUM_GPIO`: `OUT_COUNT = 32` on 8 GPIOs writes all 8 pins |
| `in pins`, `mov x, pins` | Still 32-bit values; bits `NUM_GPIO` and up read 0 |

With `NUM_GPIO = 32` everything is exactly the RP2040 behaviour.

Example, 8 GPIOs, `SET_BASE = 6`, `SET_COUNT = 4`: `set pins, 0b0101` drives GPIO 6 = 1, 7 = 0, 0 = 1, 1 = 0.

**If you don't need the host side yet**, tie it to constants in the top level: `en = 1`, `restart = 0`, `clkdiv_restart = 0`, `force_valid = 0`, `clkdiv = 32'h0001_0000` (full speed), and whatever `pinctrl`/`execctrl`/`shiftctrl` your program needs. The testbench does exactly this: it plays the host and drives these ports directly.

## 2. Helpers

Small functions used throughout. They are `automatic`, so every call gets its own local variables; in synthesis they become plain wiring and small comparisons.

- `lowmask(n)` is `NUM_GPIO` bits wide and saturates: `n >= NUM_GPIO` gives all ones.
- `rotl(v, s)` and `rotr(v, s)`: `NUM_GPIO`-bit rotates by a `$clog2(NUM_GPIO)`-bit amount. Pin ranges wrap after the last GPIO, so mapping data onto pins is a rotate, not a shift.
- `bitrev(v)`: bit reversal. Bit 0 goes to bit 31, bit 1 to bit 30, and so on; the `for` loop is unrolled into 32 crossed wires. Used for the MOV bit-reverse operation, `mov x, ::y` (`mov_op = 2`). Useful when a protocol is MSB-first but the data is stored LSB-first.
- `count32(n)`: 5-bit count fields can only hold 0..31, but the PIO needs 32-bit shifts, so **0 encodes 32** (a count of 0 would be useless anyway). The result is 6 bits because 32 needs a 6th bit. Used for `PULL_THRESH`/`PUSH_THRESH`.

| Field value | `count32` |
|---|---|
| 0 | 32 |
| 1 | 1 |
| 31 | 31 |

## 3. Configuration fields

These are plain `assign`s that slice the config registers into named fields (`wrap_top`, `pull_thresh`, `out_base`, ...), so the rest of the code never uses raw bit ranges. The thresholds go through `count32`, so `pull_thresh` / `push_thresh` are 6-bit values in the range 1..32. The counts are clamped: SET and side-set to at most 5, OUT to at most 32, so bad config values can't break the masks.

Bits not listed are unused by `sm`. The full tables are in RP2040 datasheet section 3.7.

**CLKDIV**: speed

| Bits | Field | Signal | Meaning |
|---|---|---|---|
| 31:16 | `INT` | `div_int` | Integer part of the divisor (0 means 65536) |
| 15:8 | `FRAC` | `div_frac` | Fractional part, in 1/256 steps |

`32'h0001_0000` runs one instruction per clock; `32'h0002_8000` is divisor 2.5.

**EXECCTRL**: program flow

| Bits | Field | Signal | Used for |
|---|---|---|---|
| 30 | `SIDE_EN` | `side_en` | Top side-set bit is an enable, so side-set is optional per instruction (to `decode`) |
| 29 | `SIDE_PINDIR` | `side_pindir` | Side-set drives pin directions (`dirs_we`) instead of values (`pins_we`) |
| 28:24 | `JMP_PIN` | `jmp_pin` | The GPIO that `jmp pin` tests |
| 16:12 | `WRAP_TOP` | `wrap_top` | After this address, go to `WRAP_BOTTOM` |
| 11:7 | `WRAP_BOTTOM` | `wrap_bottom` | Start of the loop |
| 4 | `STATUS_SEL` | `status_sel` | `mov x, status` compares 0 = TX level, 1 = RX level |
| 3:0 | `STATUS_N` | `status_n` | ...against this level |

**SHIFTCTRL**: ISR/OSR behaviour

| Bits | Field | Signal | Used for |
|---|---|---|---|
| 29:25 | `PULL_THRESH` | `pull_thresh` | After this many bits shifted out, the OSR counts as empty (autopull, `pull ifempty`) |
| 24:20 | `PUSH_THRESH` | `push_thresh` | After this many bits shifted in, the ISR counts as full (autopush, `push iffull`) |
| 19 | `OUT_SHIFTDIR` | `out_dir` | 1 = OSR shifts right (LSB first), 0 = left (MSB first) |
| 18 | `IN_SHIFTDIR` | `in_dir` | Same, for the ISR |
| 17 | `AUTOPULL` | `autopull` | Enable autopull |
| 16 | `AUTOPUSH` | `autopush` | Enable autopush |

**PINCTRL**: which GPIOs each instruction uses

| Bits | Field | Signal | Used for |
|---|---|---|---|
| 31:29 | `SIDESET_COUNT` | `sideset_count` | Side-set bits per instruction, 0..5, incl. the enable bit if `SIDE_EN` |
| 28:26 | `SET_COUNT` | `set_count` | Pins `set pins` writes, 0..5 |
| 25:20 | `OUT_COUNT` | `out_count` | Pins `out pins` / `mov pins` write, 0..32 |
| 19:15 | `IN_BASE` | `in_base` | First GPIO for `in pins` and `wait pin` |
| 14:10 | `SIDESET_BASE` | `sideset_base` | First GPIO for side-set |
| 9:5 | `SET_BASE` | `set_base` | First GPIO for `set` |
| 4:0 | `OUT_BASE` | `out_base` | First GPIO for `out` / `mov pins` |

Each group of pins is a contiguous range starting at the base. With `SET_BASE = 3` and `SET_COUNT = 2`, `set pins, 0b11` drives GPIO 3 and 4. The same program can drive different pins, or run at a different speed, just by changing these words.

Example, UART TX on GPIO 0, LSB first:

```systemverilog
pinctrl   = (1 << 29)        // SIDESET_COUNT = 1
          | (0 << 10)        // SIDESET_BASE  = GPIO 0
          | (1 << 20)        // OUT_COUNT     = 1
          | (0 << 0);        // OUT_BASE      = GPIO 0
shiftctrl = (1 << 19);       // OUT_SHIFTDIR  = right
execctrl  = (3 << 12)        // WRAP_TOP      = 3
          | (0 << 7);        // WRAP_BOTTOM   = 0
```

## 4. Submodules

**decode**: purely combinational. Section 6 describes it.

**clockdiv**: `tick` is high for one cycle every `INT + FRAC/256` cycles on average. The SM only runs program instructions when `ce = en & tick`. The clock itself is never divided. `clkdiv_restart` resets the divider so it ticks on the next cycle.

**regfile (X, Y)**: instantiated with `NUMREGS = 3`, and register 0 is the hardwired zero. A *port* here means one access path into the register storage (not a module port): `regfile.sv` has two read ports (`src_reg_1`→`r_data_1`, `src_reg_2`→`r_data_2`, combinational) and one write port (`dest_reg`, `w_data`, `w_en`, written on the falling edge), so it can do two reads and one write per cycle. In a CPU the read addresses change every instruction; here the two read ports are tied permanently to X (`src_reg_1 = 1`) and Y (`src_reg_2 = 2`). JMP X!=Y needs both at once, so `x` and `y` are always available. One write port (`xy_we`, `xy_addr`, `xy_wdata`) is enough, because no instruction writes both. **The regfile writes on the falling clock edge**; see section 7 for why this matters.

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

### `stall` vs `done`

They are the two possible outcomes of an instruction that runs this cycle; both only matter when `active = 1`:

| `active` | `stall` | `done` | Meaning |
|---|---|---|---|
| 0 | – | 0 | Nothing runs: disabled, no tick, or a delay cycle |
| 1 | 1 | 0 | The instruction ran but **can't finish**, so it repeats next time |
| 1 | 0 | 1 | The instruction **finished** |

`stall` is combinational, worked out from the current instruction and conditions (the list is in section 7). `done` gates every effect: X/Y, ISR, OSR and pin writes, FIFO pops and pushes, moving the PC, loading the delay counter, clearing `exec_pending`. A stalled instruction leaves no trace, so retrying it is safe. The two exceptions are side-set (gated by `active`) and `irq wait`, which sets its flag on the first stalled cycle.

Example, `pull block` with the TX FIFO empty for 2 cycles:

| Cycle | TX empty | `active` | `stall` | `done` | Effect |
|---|---|---|---|---|---|
| 0 | 1 | 1 | 1 | 0 | PC holds, side-set applies |
| 1 | 1 | 1 | 1 | 0 | PC holds |
| 2 | 0 | 1 | 0 | 1 | OSR loads, FIFO pops, PC moves on |

### Forced instructions and `run_latched`

`force_valid` is a **one-cycle pulse**. Most forced instructions (`set pindirs, 1`, `jmp 0`) finish in that cycle. But some can stall: `wait 1 gpio 5` with GPIO 5 low, `pull block` with TX empty, `push block` with RX full. On the next cycle `force_valid` is gone, but the instruction still has to finish, so `sm`:

1. **Cycle 0** (`force_valid = 1`, stalls): copies the instruction into `exec_latch` and sets `exec_pending = exec_forced = 1` at the clock edge.
2. **Following cycles**: `run_latched = !force_valid && exec_pending && exec_forced` is 1, so the latched copy runs again. `exec_stalled = 1` tells the host it is stuck.
3. **The cycle it completes**: `done` clears `exec_pending` and `exec_forced`, and normal execution resumes.

`exec_pending` is a flop: it holds its value until something sets or clears it, so it stays 1 through every retry cycle. It is still 0 *during* cycle 0 (nonblocking assignments update at the edge); in cycle 0 the instruction comes straight from `force_instr`, which has priority in the `ins` mux.

The host can force instructions **while the SM is disabled** (that's the usual setup step), so the retry ignores `en` and the divider as well and runs on every clock. That's why `run_latched` has no `ce` and `run_prog` does.

Example, SM disabled, host forces `wait 1 gpio 5`:

| Cycle | `force_valid` | GPIO 5 | `stall` | `done` | `exec_pending`/`exec_forced` during | after the edge |
|---|---|---|---|---|---|---|
| 0 | 1 | 0 | 1 | 0 | 0 / 0 | **1 / 1** (latched) |
| 1 | 0 | 0 | 1 | 0 | 1 / 1, `run_latched` | 1 / 1 |
| 2 | 0 | 0 | 1 | 0 | 1 / 1, `run_latched` | 1 / 1 |
| 3 | 0 | 1 | 0 | **1** | 1 / 1, `run_latched` | **0 / 0** |
| 4 | 0 | – | – | – | 0 / 0, normal program | |

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

### Destination constants

`sm.sv` defines `OUT_*`, `MOV_*` and `SET_*` localparams. They name the values of `arg1` (bits 7:5) when it is a **destination**. You don't write them in programs: the assembler turns `out pins, 1` into `arg1 = 0`, and `sm.sv` compares `arg1 == OUT_PINS`.

```
assembly:      out pins, 1
machine code:  011 00000 000 00001
               OUT delay dest count
sm.sv:         arg1 = 3'd0  ->  arg1 == OUT_PINS  ->  bits go to the GPIOs
```

| Value | OUT (n bits from the OSR) | MOV (32-bit copy) | SET (5-bit constant) |
|---|---|---|---|
| 0 | `OUT_PINS`: GPIOs from `OUT_BASE` | `MOV_PINS`: GPIOs from `OUT_BASE` | `SET_PINS`: GPIOs from `SET_BASE` |
| 1 | `OUT_X` | `MOV_X` | `SET_X` |
| 2 | `OUT_Y` | `MOV_Y` | `SET_Y` |
| 3 | NULL (discard) | reserved | reserved |
| 4 | `OUT_PINDIRS`: pin directions | `MOV_EXEC`: run as next instruction | `SET_PINDIRS` |
| 5 | `OUT_PC`: jump to the data | `MOV_PC`: jump to the value | reserved |
| 6 | `OUT_ISR` (ISR count = n) | `MOV_ISR` (ISR count = 0) | reserved |
| 7 | `OUT_EXEC`: run as next instruction | `MOV_OSR` (OSR marked full) | reserved |

The same number means different things for each opcode, so the code always checks the opcode first, e.g. `is_out && arg1 == OUT_PC`. `FULL = 32` is not a destination; it is the maximum bit count, 6 bits wide because 32 doesn't fit in 5.

## 7. Operands, conditions and stalls

### Operands

- `in_rot = rotr(gpio_in, in_base)` puts GPIO `IN_BASE` at bit 0, and `in_pins` is `in_rot` zero-extended to 32 bits. IN PINS, MOV PINS and WAIT PIN all use it. This is because input pins are counted **relative to `IN_BASE`**, and the ISR takes the **low n bits** of its source. With `IN_BASE = 4`, `in pins, 3` must read GPIO 4, 5, 6; after the rotate they are bits 0, 1, 2. Likewise `wait 1 pin 2` is just `in_rot[2]` (the index is taken modulo `NUM_GPIO`, as `wait_idx`). A rotate (not a shift) makes the range wrap from the last GPIO to GPIO 0, as the RP2040 wraps from GPIO 31. Outputs do the reverse: data starts at bit 0 and is rotated *left* by the base onto the pins.
- `in_src`: the IN source (PINS, X, Y, NULL, ISR or OSR).
- `mov_src`: the MOV source (adds STATUS). `mov_val` is `mov_src` after the MOV operation: none, invert (`~`) or bit-reverse.
- `status` is all ones when the TX level (or the RX level, if `STATUS_SEL` = 1) is less than `STATUS_N`.

### JMP conditions

**JMP** (jump) loads the PC with a different address instead of the next one; it's how PIO programs make loops and decisions. It can be **conditional**: jump only if something is true, otherwise fall through to the next instruction.

```
jmp x--, 1
    ───  ─
     │   └─ arg2 (bits 4:0): target address
     └───── arg1 (bits 7:5): which condition
```

In the table, **`arg1`** is the number stored in the instruction, **Condition** is how you write it in assembly, and **Test** is the expression `sm.sv` evaluates as `jmp_cond`. If it's 1 the jump happens (`branch_en = 1`, `branch_addr = arg2`); otherwise the PC moves on normally.

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

In words: `!x`/`!y` jump when the register is zero; `x--`/`y--` jump when it is **not** zero and decrement it either way; `x!=y` when they differ; `pin` when the `JMP_PIN` GPIO is high; `!osre` when the OSR still has bits to shift out.

The common counted loop, sending 8 bits:

```
    set x, 7        ; X = 7, so the body runs 8 times
loop:
    out pins, 1
    jmp x--, loop   ; X != 0: X = X-1 and jump back. X == 0: X becomes -1, fall through
```

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

These are **strobes**: one-cycle "do this now" commands from the control logic to the `isr` module and the RX FIFO. Each is 1 only in the cycle an instruction finishes and needs that action. The ISR holds a value `isr_q` and a count `isr_cnt` of bits collected.

| Strobe | When | What it does |
|---|---|---|
| `isr_shift` | A completed IN that does **not** autopush | Shift n new bits in; count += n |
| `isr_clear` (to isr `rst`) | IN with autopush, or a PUSH that is not skipped | Value and count back to 0, because the contents were just sent |
| `isr_load` | MOV ISR (count 0) or OUT ISR (count = bit count) | Overwrite the value; `isr_load_cnt` sets the count |
| `rx_push` | IN with autopush, or a PUSH that is not skipped, if the FIFO is not full | Write strobe into the RX FIFO |

`rx_data` is `isr_shift_q` for an autopush and `isr_q` for a PUSH.

- **IN with autopush** doesn't shift and then push on a later cycle. In one cycle, `sm` takes the value the ISR *would* have after the shift (`isr_shift_q`), pushes it, and clears the ISR. That's why `isr_shift` excludes this case.
- **Skipped**: `push iffull` below the threshold does nothing at all (`push_skip`).
- **FIFO full**: `push block` stalls; `push noblock` completes, clears the ISR, but drops the data. That's why `rx_push` has `!rx_full` and `isr_clear` doesn't.

With autopush at 8 bits:

| Instruction | ISR count before | Strobes | Result |
|---|---|---|---|
| `in pins, 1` | 0 | `isr_shift` | count 1 |
| ... 6 more | 1..6 | `isr_shift` | up to count 7 |
| `in pins, 1` | 7 | `isr_clear` + `rx_push` | 8 bits to the RX FIFO, count 0 |

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

Example (32 GPIOs): OUT_BASE = 16 and OUT_COUNT = 8. `mov pins, x` gives `pins_we = 0x00FF0000`, and only GPIO 16..23 change. With 8 GPIOs, OUT_BASE = 6 and OUT_COUNT = 3 give `pins_we = 0xC1`: GPIO 6, 7 and 0.

The SM does **not** store pin values. The top level keeps the output registers and applies the masks (and merges several SMs):

```systemverilog
gpio_out <= (gpio_out & ~pins_we) | (pins_wdata & pins_we);
```

### IRQ

- `irq_set` comes from IRQ (set or wait). It fires **only while `irq_waiting` is 0**, so an IRQ WAIT sets its flag once and doesn't keep re-setting it while waiting.
- `irq_clr` comes from `irq clear` and from `wait 1 irq n` when it completes.

IRQ stands for *interrupt request*. The 8 flags are shared: SMs set and wait on them to synchronise with each other, and flags 0..3 can interrupt the host. The flag register lives outside `sm` and merges all requests:

```systemverilog
irq_flags <= (irq_flags & ~(irq_clr | host_irq_clr)) | irq_set | host_irq_set;
```

The host clears a flag by **writing 1** to its bit in the `IRQ` register (write-1-to-clear); writing 0 does nothing. That way the host can't accidentally erase a flag an SM set between the host's read and write. The host sets flags through `IRQ_FORCE`. In the top level, a write to the IRQ address drives `host_irq_clr` with the written data for one cycle, and a write to the force address drives `host_irq_set`.

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
- **GPIO count:** instantiate with `NUM_GPIO` equal to the number of pins the SM really gets (section 1), and keep the host's PINCTRL values inside that range.
- **Tests:** run `make sim_tb_sm` from `test/`. `test/modules/tb_sm.sv` runs 18 groups of small PIO programs against this module; `test/modules/tb_sm.md` walks through what each group checks.
