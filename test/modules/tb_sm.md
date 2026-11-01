# tb_sm.sv: what the state machine testbench checks

`tb_sm.sv` tests `src/modules/sm.sv` in two parts:

1. It **builds a fake world** around the state machine: instruction memory, FIFOs, GPIOs and IRQ flags.
2. It **runs 18 groups of small PIO programs** in that world and checks that the right things happen on the right cycle.

Run it from `test/`:

```bash
make sim_tb_sm
```

It prints `SM SystemVerilog test passed`, or stops at the first failing `check` with a message naming the signal, the value it got and the value it expected. The waveform is written to `sim_outputs/modules/sv/sm.fst`. Open it in GTKWave or Surfer and add `pc`, `dut.ins`, `dut.x` and `gpio_out`.

The testbench uses `SM_ID = 1`, so relative IRQ indices differ from absolute ones.

There are two state machines:

- `dut` has 32 GPIOs (the RP2040 default). Groups 1–17 check it.
- `dut8` has `NUM_GPIO = 8`. It shares the host side, instruction memory, TX FIFO and IRQ flags with `dut` and runs the same programs, but has its own GPIO model (`gpio8_out`, `gpio8_oe`, `ext8`) and PC (`pc8`). Only group 18 checks it; its FIFO and IRQ outputs are ignored.

---

## Part 1: the fake world

`sm` can't run on its own. The testbench builds simple models of the blocks around it:

| Model | What it pretends to be |
|---|---|
| Instruction memory | An array `imem[0:31]` with a combinational read. Tests write programs into it directly |
| TX FIFO | A 4-deep first-word fall-through queue. The "host" writes into it with `tx_put()` |
| RX FIFO | A 4-deep queue. The "host" reads from it with `rx_get()` |
| IRQ flags | 8 flags, set and cleared by the SM (`irq_set`/`irq_clr`) and by the host (`host_irq_set`/`host_irq_clr`, write-1-to-clear) |
| GPIOs | `gpio_out`/`gpio_oe` registers updated from `pins_we`/`dirs_we`. Pins the SM drives read back their own level; other pins read `ext_in`, which the test controls. `dut8` has an 8-bit copy: `gpio8_out`, `gpio8_oe`, `ext8` |

### Instruction encoders

These are functions such as `i_set(S_PINS, 1)`, `i_jmp(C_X_DEC, 1)` and `i_out(O_PINS, 8)`. Each builds the 16-bit machine code (RP2040 datasheet table 366), so tests read like assembly instead of hex. `dss()` fills in the delay/side-set field. `execctrl_f`, `shiftctrl_f` and `pinctrl_f` build the config words from named fields.

### Helper tasks

| Task | What it does |
|---|---|
| `reset_all()` | Resets everything to RP2040 defaults and fills instruction memory with "jump to yourself", so a stray PC just sits still. X and Y are not reset |
| `start()` | `en = 1`; cycle 0 is the first cycle after this |
| `step(n)` | Waits *n* clock cycles |
| `check(got, exp, "name")` | Stops the simulation with an error if `got != exp`. **This is what "test" means here: hundreds of `check` calls** |
| `force_exec(ins)` | Runs one instruction through the host path (`force_valid`), the way the host sets up an SM |
| `tx_put(w)` / `rx_get(w)` | The host writes to the TX FIFO / reads from the RX FIFO |
| `load_xy(xv, yv)` | Sets X and Y to 32-bit values using forced instructions |
| `check_jmp(...)` | Runs a JMP after some setup instructions. A taken jump lands at address 10, a fall-through at 4 |
| `uart_frame(pin, bit_cycles, data)` | Watches a pin and decodes one UART frame, checking each bit's length |

### Timing convention

Inputs change and checks happen 1 ns after the rising edge. Inputs must not change near the falling edge, because the scratch registers are written there.

---

## Part 2: the 17 test groups

They build up from simple to complex, so the first failing group tells you roughly where the bug is.

### Basics: does it run instructions at all?

1. **Encoders.** Checks the testbench's own encoders against the hex that pioasm produces in the datasheet. Without this, every later test could share the same encoding mistake and still pass.
2. **One instruction per cycle, SET, wrap.** Runs the datasheet's `squarewave_fast`: `set pindirs, 1`, then `set pins, 1` / `set pins, 0` looping with wrap 2 → 1. It checks the PC and the pin every cycle. While disabled, the PC must hold (branch to itself).
3. **Delay.** The same square wave with `[1]` delay on each instruction. The period doubles, and the PC and delay counter are checked during delay cycles.
4. **Clock divider and enable.**
   - At divisor 3, instruction *j* runs in cycle 3*j*.
   - Turning `en` off freezes the PC and the pins.
   - At divisor 2.5, exactly 40 instructions run in 100 cycles.

### Control flow

5. **JMP conditions.** All 8 conditions, taken and not taken. It loads X/Y, jumps, and checks that the PC lands at 10 (taken) or 4 (not taken). Edge cases:
   - `x--` from 0 wraps X to `FFFFFFFF`;
   - `!osre` is checked with the OSR empty after reset, full after a PULL, and with `PULL_THRESH = 8`.
6. **The `x--` loop, cycle by cycle.** It checks the tricky timing: X is written on the falling edge, but the jump decision must use X *before* the decrement (`x_nz_q`).

### Data movement: the core of the PIO

7. **Autopull/autopush loopback** (datasheet figure 44). `out x, 32` / `in x, 32`, so data written to TX comes back out of RX. It checks on which cycles the TX pops and RX pushes happen:
   - OUT stalls in cycle 0 while the OSR fills;
   - after that, the OSR refills in the same cycle as each OUT;
   - each IN pushes straight away;
   - OUT stalls when TX is drained, and IN stalls on autopush when RX is full.
8. **PULL → OUT PINS → IN PINS → PUSH** in both shift directions. Real data passes through real pins and comes back.
9. **PUSH/PULL variants:**
   - `pull noblock` on an empty FIFO copies X; `pull block` stalls;
   - `push noblock` on a full FIFO drops the data; `push block` stalls;
   - `pull ifempty` / `push iffull` with thresholds of 8;
   - with autopull, `pull` is a no-op while the OSR is full, and the OSR refills in the background between OUTs.
10. **MOV.** Every source, every destination, and the invert and bit-reverse operations.

### Pins and timing

11. **Side-set.**
    - The datasheet's `spi_tx_fast`: data on GPIO 3, clock driven by side-set on GPIO 2.
    - With TX empty, OUT stalls but its side-set still drives the clock low.
    - Optional side-set (`SIDE_EN`) together with delay bits.
    - Side-set beats SET on the same pin.
    - `SIDE_PINDIR` drives directions instead of levels.
12. **WAIT.**
    - `wait gpio`: delay cycles start only after the wait completes.
    - `wait pin` uses `IN_BASE`: pin 3 with `IN_BASE = 10` is GPIO 13.
    - `wait 1 irq` clears the flag when it completes. The relative index `0x13` on SM 1 is flag 0.

### Signaling and the host

13. **IRQ.** Set, clear, `irq wait` (sets the flag once, then stalls until it is cleared), and relative indices.
14. **EXEC and PC writes.** `out exec` / `mov exec` run data as an instruction. `out pc` / `mov pc` jump to an address taken from data.
15. **Forced instructions (SMx_INSTR).**
    - They run while disabled and ignore the divider.
    - Their delay field is ignored.
    - A stalled one is latched and retried until it completes, with `exec_stalled` high meanwhile.
16. **SM_RESTART.** Clears the internal state (ISR, OSR, delay, stall latch) but keeps X, Y and the PC.

### The final exam

17. **End to end: `uart_tx` from the datasheet, at two baud rates.** The host puts bytes in the TX FIFO, the real UART program runs, and `uart_frame()` watches the pin. It checks:
    - the start bit;
    - 8 data bits, LSB first;
    - the stop bit;
    - that each bit lasts exactly the right number of cycles.

    It then decodes the byte and compares it with what was sent. If this passes, the state machine works as a real peripheral.

### Small GPIO count

18. **`NUM_GPIO = 8` (`dut8`).** Pin ranges wrap at GPIO 7 and GPIO numbers are taken modulo 8:
    - SET with `SET_BASE = 6`, `SET_COUNT = 4` drives GPIO 6, 7, 0, 1 (on `dut` it's GPIO 6..9). `SET_BASE = 14` gives the same result.
    - `mov pins, x` with `OUT_COUNT = 32` writes all 8 pins (the mask saturates), rotated by `OUT_BASE = 13` (= 5).
    - `OUT_COUNT = 3` at `OUT_BASE = 6` writes GPIO 6, 7, 0.
    - Side-set at `SIDESET_BASE = 15` (= 7) with 2 bits drives GPIO 7 and 0.
    - `mov x, pins` with `IN_BASE = 6` reads GPIO 6, 7, 0..5, and bits 8 and up are 0. `IN_BASE = 13` (= 5, an odd base) reads GPIO 5, 6, 7, 0..4.
    - `wait 1 pin 3` with `IN_BASE = 6` waits on GPIO 1; `wait 1 gpio 10` waits on GPIO 2; `JMP_PIN = 11` tests GPIO 3.

---

## What a single test looks like

From group 2:

```systemverilog
reset_all();
imem[0] = i_set(S_PINDIRS, 1);          // load the program
imem[1] = i_set(S_PINS, 1);
imem[2] = i_set(S_PINS, 0);
execctrl = execctrl_f(0, 0, 0, 2, 1, 0, 0);   // wrap 2 -> 1
pinctrl  = pinctrl_f(0, 1, 0, 0, 0, 3, 0);    // SET drives GPIO 3
start();
step(1);
check(gpio_oe[3], 1, "set pindirs");     // after 1 cycle, pin 3 is an output
check(pc, 1, "pc after set pindirs");
for (int i = 0; i < 10; i++) begin
    step(1);
    check(gpio_out[3], (i % 2 == 0), "squarewave level");   // toggles every cycle
    check(pc, (i % 2 == 0) ? 2 : 1, "squarewave pc");       // 1, 2, 1, 2...
end
```

Every group follows the same pattern:

1. reset;
2. write a small program into `imem`;
3. set the config words;
4. start;
5. step cycle by cycle and `check` pins, PC, registers and FIFOs.
