# tb_sm_uart.sv: UART test for the simplified state machine

`tb_sm_uart.sv` checks that `src/modules/sm_no_smx_instr.sv`, built with `DATA_WIDTH = 8`, works as a real UART. It runs the UART transmit and receive programs from the RP2040 datasheet on two state machines, and checks the waveforms on the pins and the bytes in the FIFOs.

Run it from `test/`:

```bash
make sim_tb_sm_uart
```

It prints `SM UART SystemVerilog test passed`, or stops at the first failing check with a message naming what failed, the value it got and the value it expected. The waveform is written to `sim_outputs/modules/sv/sm_uart.fst`.

Icarus prints a few `sorry: constant selects in always_* processes` notices for `sm_no_smx_instr.sv`. They are harmless.

---

## 1. Setup

```
                +--------------+
  host -------> |   TX FIFO    |
                +--------------+
                        |
                        v
                +--------------+  GPIO 6
                | tx_sm (SM 0) |------------> tx_line
                |   uart_tx    |                 |
                +--------------+                 | loopback = 1
                                                 v
                                            +---------+
         drv_line (testbench) ------------> |   mux   |
                         loopback = 0       +---------+
                                                 |
                                                 | rx_line, GPIO 2
                +--------------+                 |
                | rx_sm (SM 1) | <---------------+
                |   uart_rx    | ----> IRQ flag 5 (framing error)
                +--------------+
                        |
                        v
                +--------------+
  host <------- |   RX FIFO    |
                +--------------+
```

| Item | Value | Why |
|---|---|---|
| `DATA_WIDTH` | 8 | X, Y, ISR, OSR, FIFO words and GPIOs are all 8 bits |
| TX pin (`TXP`) | GPIO 6 | Not GPIO 0, so the pin mapping is actually exercised |
| RX pin (`RXP`) | GPIO 2 | |
| `tx_sm` | `SM_ID = 0` | |
| `rx_sm` | `SM_ID = 1` | `irq 4 rel` on SM 1 sets flag 4 + 1 = **5** |
| Bit time | 8 SM cycles | Both programs spend 8 instructions/delay cycles per bit |
| Clock divisor | shared `clkdiv` | Both SMs tick together. Bit time in clocks = 8 × divisor |

### What the testbench instantiates

Only `tx_sm` and `rx_sm` are real module instances, both of `sm_no_smx_instr`. Every other box is a small model written directly inside `tb_sm_uart.sv`. The arrows are the signals connected to each SM's ports.

```
 tx_put()
    |  host_tx_we, host_tx_wdata
    v
+---------+  tx_data, tx_empty, tx_level   +-------------------+
| TX FIFO | -----------------------------> |       tx_sm       | <-- clk, rst, en_tx, clkdiv
| 4 deep  | <----------------------------- |  sm_no_smx_instr  | <-- tx_execctrl, tx_shiftctrl,
+---------+  tx_pop                        |  SM_ID = 0        |     tx_pinctrl
                                           |  DATA_WIDTH = 8   |
+---------+  instr                         |                   |
| tx_imem | -----------------------------> |                   |
| 32 x 16 | <----------------------------- |                   |
+---------+  mem_addr (tx_pc)              +-------------------+
                                                |         ^
              pins_we/wdata, dirs_we/wdata,     |         |  gpio_in,
              irq_set, irq_clr                  |         |  irq_flags
                                                v         |
                                           +-------------------+
                                           |   Shared models   |  tx_line (GPIO 6)
host_irq_clr ----------------------------> |  gpio_out         | -------------------+
                                           |  gpio_oe          |                    | loopback = 1
                                           |  irq_flags        |  rx_line (GPIO 2)  v
                                           |  pad logic        | <---------------- mux <-- drv_line
                                           +-------------------+                     (loopback = 0)
                                                ^         |
              pins_we/wdata, dirs_we/wdata,     |         |  gpio_in,
              irq_set, irq_clr                  |         |  irq_flags
                                                |         v
+---------+  instr                         +-------------------+
| rx_imem | -----------------------------> |       rx_sm       | <-- clk, rst, en_rx, clkdiv
| 32 x 16 | <----------------------------- |  sm_no_smx_instr  | <-- rx_execctrl, rx_shiftctrl,
+---------+  mem_addr (rx_pc)              |  SM_ID = 1        |     rx_pinctrl
                                           |  DATA_WIDTH = 8   |
+---------+  rx_data, rx_push              |                   |
| RX FIFO | <----------------------------- |                   |
| 4 deep  | -----------------------------> |                   |
+---------+  rx_full, rx_level             +-------------------+
    |
    |  host_rx_re
    v
 rx_get()
```

Each SM only uses one side of the FIFO ports. `tx_sm`'s RX FIFO inputs and `rx_sm`'s TX FIFO inputs are tied off, so they are not drawn. `restart` and `clkdiv_restart` are tied to 0 on both.

### Why each SM has its own instruction memory

`sm_no_smx_instr` has no forced-instruction port, so nothing outside can set the PC. After reset every SM starts at address 0. If both SMs shared one memory, both would run the same program. The testbench gives each SM its own 32-word memory (`tx_imem`, `rx_imem`). The real top level needs the same thing, or a per-SM start address.

### Pins

- Each SM's `pins_we`/`dirs_we` masks update shared `gpio_out` / `gpio_oe` registers.
- A pin that nothing drives reads **high**, like a UART line with a pull-up. So the RX side sees an idle line before the TX side has set its pin direction.
- `tx_line` is the TX pin: `gpio_out[TXP]` once it is an output, otherwise high.
- `rx_line` is the RX pin: `tx_line` when `loopback = 1`, otherwise `drv_line`, which the testbench drives.
- The testbench plays two roles, and they never mix:
  - As the **host**, it only touches the FIFOs and IRQ flags (`tx_put`, `rx_get`, `host_irq_clr`).
  - As the **external device** on the other end of the UART wire, it only touches `drv_line` (through `drive_frame`).

  On a real chip, GPIO 2 would be wired to another device's TX pin; `drv_line` stands in for that pin. With `loopback = 1`, our own TX SM plays the external device instead.

---

## 2. The programs

### Reading a PIO instruction

Every instruction has the same shape:

```
opcode  destination/source/condition, value/count/address  side S  [D]
```

| Part | Meaning |
|---|---|
| `opcode` | What to do: `set`, `pull`, `out`, `in`, `jmp`, `wait`, `irq`, `push`, ... |
| First argument | **Where** it acts: a destination (`set pindirs`), a source (`in pins`), or a jump condition (`jmp x--`) |
| Second argument | **How much / which**: a constant (`set x, 7`), a bit count (`out pins, 1`), or a jump target address |
| `side S` | Optional. While this instruction runs, also drive the side-set pins to `S` |
| `[D]` | Optional. After the instruction finishes, wait `D` extra cycles before the next one |
| Labels (`bitloop:`) | Names for addresses, so jumps can say `jmp bitloop` instead of `jmp 2` |

The 16-bit hex splits the same way:

```
 15  13 12        8 7      5 4        0
[opcode][side + delay][dest/src][value/count]
```

The 5-bit `side + delay` field is shared. In `uart_tx`, side-set is 1 bit and optional, so the field is `[enable][side value][3 delay bits]`: the enable says whether this instruction side-sets at all, and delays can be at most 7. `uart_rx` uses no side-set, so all 5 bits are delay (up to 31).

**Timing:** every instruction takes 1 cycle plus its delay, unless it stalls (a `wait` whose condition isn't true yet, a `pull` on an empty FIFO, a `push` on a full one). One UART bit is 8 cycles, so each program is arranged so that exactly 8 cycles pass per bit.

### uart_tx (on `tx_sm`)

The datasheet program with one instruction added in front. Without forced instructions, the host can't run `set pindirs` for it, so the program sets its own pin direction. The wrap goes back to address 1, so that first instruction only runs once.

| Addr | Assembly | Hex | Summary |
|---|---|---|---|
| 0 | `set pindirs, 1 side 1` | `F881` | Make the TX pin an output and drive it high. Runs once |
| 1 | `pull side 1 [7]` | `9FA0` | Get the next byte. The line is high: **stop bit**, or idle while waiting |
| 2 | `set x, 7 side 0 [7]` | `F727` | Start the bit counter. The line is low: **start bit** |
| 3 | `out pins, 1` | `6001` | Send one data bit |
| 4 | `jmp x-- 3 [6]` | `0643` | Repeat for 8 bits |

Config: side-set 1 bit, optional (`SIDESET_COUNT = 2`, `SIDE_EN = 1`); OUT, SET and side-set all start at GPIO 6; OUT shifts right (LSB first); wrap 4 → 1.

**0. `set pindirs, 1 side 1`**
- `set`: write a small constant (0–31) that is stored in the instruction itself.
- `pindirs`: the destination is the **direction** of the pins in the SET range. `SET_BASE = 6` and `SET_COUNT = 1`, so only GPIO 6.
- `1`: the constant. A direction of 1 means output.
- `side 1`: at the same time, drive the side-set pin (also GPIO 6) to 1, so the line goes high as soon as it becomes an output.
- Result: the TX line is an output and idles high. Afterwards the wrap never comes back here.

**1. `pull side 1 [7]`**
- `pull`: move the next word from the TX FIFO into the OSR (the output shift register). With no options it is `pull block`: if the FIFO is empty, the SM **stalls** here until the host writes a byte.
- `side 1`: drive the line high. Side-set happens even while stalled, so the line stays high the whole time it waits. That is the UART idle level.
- `[7]`: after the pull succeeds, wait 7 more cycles while still driving `side 1`. The line is high for 1 + 7 = 8 cycles.
- Why 8 cycles matters: UART has no clock wire, so each bit is sent by holding the line at a level for a fixed time, the **bit time**. This program uses 8 SM cycles per bit. Holding the line high for 8 cycles is therefore exactly one **stop bit**. The loop comes back to this instruction right after the last data bit, so this is the stop bit of the byte just sent. Before the very first byte it is just extra idle time, which is also high and therefore harmless. If the FIFO is empty, the stall keeps the line high even longer, and the receiver sees that as idle.

**2. `set x, 7 side 0 [7]`**
- `set`: write a constant.
- `x`: the destination is scratch register X, used as the bit counter.
- `7`: X = 7. The loop below runs while X counts 7, 6, ..., 0, which is 8 times, once per data bit.
- `side 0`: drive the line low: the **start bit**.
- `[7]`: 1 + 7 = 8 cycles, so the start bit lasts exactly one bit time.

**3. `out pins, 1`**
- `out`: shift bits out of the OSR and send them somewhere.
- `pins`: the destination is the pin **values** in the OUT range. `OUT_BASE = 6` and `OUT_COUNT = 1`, so GPIO 6.
- `1`: the bit count: one bit per `out`. The OSR shifts right, so the byte goes out least-significant bit first, as UART requires.
- No `side`: the side-set enable bit is 0, so side-set leaves the pin alone and the `out` value is what appears.

**4. `jmp x-- 3 [6]`** (written `jmp x-- bitloop [6]` in the datasheet, where `bitloop` is address 3)
- `jmp`: go to another address if the condition is true; otherwise continue to the next instruction.
- `x--`: the condition is "X is not zero", tested **before** X is decremented. X is decremented either way.
- `3`: the target address, the `out` above.
- `[6]`: wait 6 more cycles. With the `out` (1 cycle) and the `jmp` itself (1 cycle), each data bit lasts 1 + 1 + 6 = 8 cycles.
- Result: after the 8th bit X was 0, so the jump falls through. Address 4 is `WRAP_TOP`, so the PC wraps to address 1: `pull` drives the stop bit and fetches the next byte.

With `DATA_WIDTH = 8`, `pull` loads the whole byte into the 8-bit OSR and the eight `out pins, 1` empty it exactly.

### uart_rx (on `rx_sm`)

The datasheet `uart_rx` program, with framing-error detection.

| Addr | Label | Assembly | Hex | Summary |
|---|---|---|---|---|
| 0 | `start` | `wait 0 pin 0` | `2020` | Wait for the start bit |
| 1 | | `set x, 7 [10]` | `EA27` | Start the bit counter, then move to the middle of data bit 0 |
| 2 | `bitloop` | `in pins, 1` | `4001` | Sample one data bit |
| 3 | | `jmp x-- bitloop [6]` | `0642` | Repeat for 8 bits |
| 4 | | `jmp pin good_stop` | `00C8` | Check the stop bit |
| 5 | | `irq 4 rel` | `C014` | Bad stop bit: raise the framing-error flag |
| 6 | | `wait 1 pin 0` | `20A0` | Wait for the line to go back high |
| 7 | | `jmp start` | `0000` | Throw the frame away and start again |
| 8 | `good_stop` | `push` | `8020` | Good frame: send the byte to the RX FIFO |

Config: `IN_BASE = 2` and `JMP_PIN = 2`, so `pin 0` and `jmp pin` both mean GPIO 2; IN shifts right; wrap 8 → 0.

**0. `wait 0 pin 0`** (label `start`)
- `wait`: stall until a condition is true.
- `0`: the polarity: wait for the source to be **0**.
- `pin`: the source is an input pin, numbered relative to `IN_BASE`.
- `0`: pin index 0, i.e. `IN_BASE + 0` = GPIO 2, the RX line.
- Result: the SM sits here while the line is idle-high, and moves on in the first cycle the line is low: the start of the start bit.

**1. `set x, 7 [10]`**
- `x`, `7`: X = 7, the bit counter (8 data bits), as in `uart_tx`.
- `[10]`: wait 10 extra cycles. Counting the `wait` cycle (cycle 0) and this instruction (cycle 1), the first sample happens in cycle 12. That is 1.5 bit times after the falling edge: past the start bit and into the **middle** of data bit 0. Sampling mid-bit gives the most margin against small baud-rate differences.

**2. `in pins, 1`** (label `bitloop`)
- `in`: shift bits from a source into the ISR (the input shift register).
- `pins`: the source is the input pins starting at `IN_BASE` = GPIO 2.
- `1`: the bit count: one bit per sample. The ISR shifts right, so each new bit enters at the top and moves down. After 8 samples the first bit received (the LSB) is at bit 0.

**3. `jmp x-- bitloop [6]`**
- Same as in `uart_tx`: jump back to `bitloop` (address 2) while X was not zero, decrementing X each time.
- `[6]`: with the `in` (1) and the `jmp` (1), each sample is 8 cycles after the previous one, so every sample stays in the middle of its bit.
- After the 8th sample it falls through, landing in the middle of the stop bit.

**4. `jmp pin good_stop`**
- `jmp`: conditional jump.
- `pin`: the condition is the level of the GPIO selected by `JMP_PIN` (GPIO 2). This is a separate setting from `IN_BASE`; here both point at the RX line.
- `good_stop`: the target, address 8.
- Result: the stop bit should be 1. If it is, jump to `push`. If it is 0, fall through to the error path.

**5. `irq 4 rel`**
- `irq`: set (or clear) one of the 8 shared IRQ flags. With no `clear` or `wait` option, it sets the flag and moves on.
- `4`: the flag index.
- `rel`: relative: add this SM's number (`SM_ID`) to the low 2 bits of the index, modulo 4. On SM 1 that gives 4 + 1 = **flag 5**. This lets several RX SMs run the same program and still report errors on different flags.
- Result: flag 5 tells the host there was a framing error. The host clears it by writing 1 to that bit.

**6. `wait 1 pin 0`**
- Same as address 0 but with polarity `1`: stall until GPIO 2 is **high** again.
- Result: a long low period (a break) is treated as one error, not as many start bits.

**7. `jmp start`**
- No condition, so it always jumps to `start` (address 0). The bad byte is not pushed; the next frame's 8 `in`s replace every bit of it in the ISR.

**8. `push`** (label `good_stop`)
- `push`: send the ISR's contents to the RX FIFO and clear the ISR. With no options it is `push block`: if the RX FIFO is full, the SM **stalls** here until the host reads a byte.
- Result: the received byte is in the RX FIFO. Address 8 is `WRAP_TOP`, so the PC wraps to address 0 to wait for the next start bit.

With `DATA_WIDTH = 8`, the eight `in pins, 1` fill the 8-bit ISR exactly, so the received byte is already right-aligned when it is pushed. (On a 32-bit RP2040 it would land in the top byte.)

---

## 3. Testbench pieces

### Models

| Model | What it is |
|---|---|
| `tx_imem`, `rx_imem` | 32 × 16-bit instruction memories, combinational read |
| TX FIFO | 4 deep, first-word fall-through, feeds `tx_sm`. The host writes with `tx_put()` |
| RX FIFO | 4 deep, filled by `rx_sm`. The host reads with `rx_get()` |
| IRQ flags | 8 flags, set and cleared by both SMs; the host clears with `host_irq_clr` (write 1 to clear) |
| GPIO | Shared `gpio_out` / `gpio_oe`, pull-up on undriven pins, loopback or driven RX line |

The unused FIFO side of each SM is tied off: `tx_sm` never sees a full RX FIFO, and `rx_sm` always sees an empty TX FIFO.

### Helpers

| Task / function | What it does |
|---|---|
| `tx_prog(a)`, `rx_prog(a)` | Return the instruction at address `a` of each program, built with the instruction encoders |
| `reset_all(div)` | Reset everything, load both programs and configs, set the divisor. `div` is 16.8 fixed point: `24'h0100` = 1, `24'h0280` = 2.5. Both SMs are left disabled |
| `start()` | Enable both SMs |
| `tx_put(b)` | Host writes a byte to the TX FIFO, waiting while it is full |
| `rx_get(b, max)` | Host reads a byte from the RX FIFO, waiting up to `max` cycles for one |
| `uart_frame(bit_cycles, data, idle)` | Watches the TX line: waits for a start bit, checks every bit lasts exactly `bit_cycles`, checks start = 0 and stop = 1, returns the byte and the number of idle cycles before the start bit |
| `drive_frame(data, bit_cycles, stop)` | Drives one frame on the RX line from the testbench. `stop = 0` makes a bad stop bit. The line stays at the stop level afterwards |
| `check(got, exp, what)` | Stops the simulation with `$fatal` if `got != exp` |

Inputs change and checks happen 1 ns after the rising edge, the same convention as the other state machine testbenches.

The test bytes are `55 00 FF 01 80 A5 3C C3`: alternating bits, all zeros, all ones, and a single 1 at each end, so a wrong shift direction or a dropped end bit shows up.

---

## 4. The tests

### 1. Encoders (`test_encoders`)

Code: `tb_sm_uart.sv` lines 440–453. Called at line 562.

Checks that `tx_prog` and `rx_prog` produce the same hex as `pioasm` does for the datasheet programs. Without this, the other tests could pass with programs that differ from the real ones.

### 2. TX on its own (`test_tx`, divisors 1 and 3)

Code: `tb_sm_uart.sv` lines 458–483. Called at lines 563–564.

```
 tx_put(pattern[i])
    |
    v
+---------+         +----------------+  GPIO 6, tx_line   +--------------+
| TX FIFO | ------> |     tx_sm      | -----------------> | uart_frame() |
+---------+         |   en_tx = 1    |                    | decodes byte |
                    +----------------+                    | times bits   |
                       |          |                       +--------------+
                 tx_pc |          | gpio_oe                      |
                       v          v                              v
            check: on PULL   check: only GPIO 6       check: byte matches,
                             is an output             no gap between bytes

 rx_sm is off (en_rx = 0).
```

Only `tx_sm` runs. The test checks:

- After the first instruction, GPIO 6 is an output and **no other pin** is.
- The line idles high, and the SM waits on `pull` (address 1) while the TX FIFO is empty.
- 8 bytes, sent as two groups of 4 (one full FIFO each): every frame decodes to the byte sent, and every bit lasts exactly 8 × divisor cycles.
- Queued bytes go out back to back: the next start bit begins straight after the stop bit (`idle == 1`).
- Afterwards the line is high again, the SM is back on `pull`, and the pin directions haven't changed.

#### Line by line

`check` messages are left out to keep this short. The programs are not in the task: `reset_all` loads them into the instruction memories, and the SMs run them on their own during `step`, `tx_put`, `uart_frame` and the other tasks that let clocks pass.

```systemverilog
// ---- Startup: no data sent yet ----
reset_all(div[15:0] << 8);    // reset, load programs and config; SMs off
en_tx = 1;                    // turn on tx_sm only
step(1);                      // runs address 0: set pindirs, 1 side 1
check(gpio_oe, 8'h1 << TXP);  // GPIO 6 is an output, no other pin is
check(tx_line, 1);            // line idles high
step(20 * div);               // SM reaches pull and stalls (FIFO empty)
check(tx_line, 1);            // still high: no data, nothing sent
check(tx_pc, TX_PULL);        // PC parked at address 1

// ---- Send 8 bytes, as 2 groups of 4 (the FIFO holds 4) ----
tx_put(pattern[...]);         // x4: host writes 4 bytes
uart_frame(8 * div, b, idle); // read start + 8 data + stop off the wire,
                              // fail if any bit isn't exactly 8 * div clocks
check(b, pattern[...]);       // byte on the wire == byte the host wrote
check(idle, 1);               // bytes 2-4: start bit right after the stop bit

// ---- After sending: back to idle ----
step(30 * div);               // FIFO is empty again
check(tx_line, 1);            // line back to idle high
check(tx_pc, TX_PULL);        // SM waiting on pull again
check(gpio_oe, 8'h1 << TXP);  // still only GPIO 6 is an output
```

### 3. Loopback (`test_loopback`, divisors 1, 3 and 2.5)

Code: `tb_sm_uart.sv` lines 489–505. Called at lines 565–567.

```
 tx_put(pattern[i])
    |
    v
+---------+         +----------------+
| TX FIFO | ------> |     tx_sm      |
+---------+         |   en_tx = 1    |
                    +----------------+
                            |
                            | GPIO 6, tx_line
                            v
                     mux (loopback = 1)
                            |
                            | GPIO 2, rx_line
                            v
                    +----------------+
                    |     rx_sm      | -----> irq_flags: check still 0
                    |   en_rx = 1    | -----> rx_pc: check back at wait 0 pin 0
                    +----------------+
                            |
                            v
                       +---------+
                       | RX FIFO | -----> rx_cnt: check 0 at the end
                       +---------+
                            |
                            v
                  rx_get(b): check b == pattern[i]
```

Both SMs run with the TX pin wired to the RX pin. 8 bytes go into the TX FIFO and must come out of the RX FIFO, in order and unchanged. Afterwards there must be no extra bytes, no framing-error flag, and the RX SM must be back at `wait 0 pin 0`.

Divisor 2.5 checks a fractional clock divider: the SM ticks every 2 or 3 clocks, so bits are not all the same length in clocks. The RX still samples each bit in its middle because both SMs tick together.

#### Line by line

```systemverilog
// ---- Startup ----
reset_all(div);               // reset, load programs and config; loopback = 1
start();                      // turn on both SMs

// ---- Send 8 bytes, as 2 groups of 4 (the FIFOs hold 4) ----
tx_put(pattern[...]);         // x4: host writes 4 bytes
rx_get(b, 400 * (div >> 8) + 400);  // x4: wait for a byte in the RX FIFO, read it;
                              // fail if none arrives in time
check(b, pattern[...]);       // byte received == byte sent

// ---- After sending: nothing left over ----
step(40);                     // give any stray byte time to show up
check(rx_cnt, 0);             // RX FIFO is empty: no extra bytes
check(irq_flags, 0);          // no framing error was raised
check(rx_pc, RX_START);       // RX is back on wait 0 pin 0, ready for a start bit
```

### 4. RX and framing errors (`test_rx_framing`, divisors 1 and 2)

Code: `tb_sm_uart.sv` lines 511–541. Called at lines 568–569.

```
 drive_frame(data, bit_cycles, stop)      <- testbench as the external device
    |
    | drv_line
    v
 mux (loopback = 0)
    |
    | GPIO 2, rx_line
    v
+----------------+  irq_set, flag 5   +-----------+
|     rx_sm      | -----------------> | irq_flags | <-- host_irq_clr (host clears flag 5)
|   en_rx = 1    |                    +-----------+
+----------------+                          |
    |         |                             v
    |         | rx_pc                 check: flag 5 set after a bad frame,
    |         v                              clear after the host writes 1
    |       check: at wait 1 pin 0 (6), then back at wait 0 pin 0 (0)
    v
+---------+
| RX FIFO | -----> rx_cnt: check 0 after a bad frame (nothing pushed)
+---------+
    |
    v
 rx_get(b): check b == 0x96, then 0x69

 tx_sm is off (en_tx = 0).
```

Only `rx_sm` runs. The testbench, acting as the external device, drives the RX line.

1. A good frame (`0x96`) is received.
2. A frame with a **low stop bit** (a break) is sent, and the line is held low:
   - nothing is pushed to the RX FIFO;
   - IRQ flag 5 is set (`irq 4 rel` on SM 1);
   - the SM waits at `wait 1 pin 0` (address 6).
3. The line goes high: the SM goes back to `wait 0 pin 0`.
4. The host writes 1 to flag 5: the flag clears.
5. Another good frame (`0x69`) is received correctly, with no new error.

#### Line by line

`bc` is one bit time in clocks: `8 * div`.

```systemverilog
// ---- Startup: only RX, testbench drives the wire ----
reset_all(div[15:0] << 8);    // reset, load programs and config; SMs off
loopback = 0;                 // RX line now comes from drv_line
en_rx = 1;                    // turn on rx_sm only
step(5);                      // SM sits on wait 0 pin 0 (line is high)

// ---- A good frame ----
drive_frame(8'h96, bc, 1);    // send 0x96 on the wire, stop bit high
rx_get(b, 4 * bc);            // read it from the RX FIFO
check(b, 8'h96);              // received correctly

// ---- A bad frame: stop bit low ----
drive_frame(8'h00, bc, 0);    // send 0x00, stop bit low; line stays low
step(2 * bc);                 // RX samples the stop bit and takes the error path
check(rx_cnt, 0);             // nothing was pushed to the RX FIFO
check(irq_flags, 8'h1 << ERR_FLAG);  // IRQ flag 5 is set (irq 4 rel on SM 1)
check(rx_pc, 6);              // SM waits on wait 1 pin 0 for the line to go high

// ---- Recovery ----
drv_line = 1;                 // line goes back to high
step(bc);                     // SM leaves address 6 and jumps to 0
check(rx_pc, RX_START);       // back on wait 0 pin 0

// ---- Host clears the error flag ----
host_irq_clr = 8'h1 << ERR_FLAG;  // write 1 to clear flag 5
step(1);                      // the clear takes effect on this clock
host_irq_clr = 0;             // stop clearing
step(1);
check(irq_flags, 0);          // flag is clear

// ---- A good frame after the error ----
drive_frame(8'h69, bc, 1);    // send 0x69, stop bit high
rx_get(b, 4 * bc);            // read it from the RX FIFO
check(b, 8'h69);              // RX still works
check(irq_flags, 0);          // no new error
```

### 5. RX FIFO full (`test_rx_fifo_full`)

Code: `tb_sm_uart.sv` lines 545–559. Called at line 570.

```
 tx_put() x 5
    |
    v
+---------+         +----------------+  GPIO 6 -> mux (loopback = 1) -> GPIO 2
| TX FIFO | ------> |     tx_sm      | --------------------------------------+
+---------+         +----------------+                                       |
                                                                             |
                    +----------------+                                       |
                    |     rx_sm      | <-------------------------------------+
                    | stalls on push |
                    +----------------+
                       |          |
                       | byte 5   |
                       | waits    +--> rx_pc: check == 8 (push)
                       v
                  +-----------------+
                  |     RX FIFO     | -----> rx_cnt: check == 4 (full)
                  | bytes 1-4, full |
                  +-----------------+
                       |
                       | nothing is read until the checks above pass
                       v
                  rx_get(b) x 5: check all 5 bytes, in order
```

Loopback at divisor 1, and the host doesn't read. Five bytes are sent:

- the first four fill the RX FIFO;
- the fifth stalls the RX SM on `push` (address 8);
- reading bytes lets the fifth through, and all five come out in order.

On a real line, a sixth byte arriving during that stall would be lost. This test doesn't send one.

#### Line by line

```systemverilog
// ---- Startup ----
reset_all(24'h0100);          // divisor 1; loopback = 1
start();                      // turn on both SMs

// ---- Send 5 bytes, and the host doesn't read ----
tx_put(pattern[...]);         // x5: host writes 5 bytes
step(5 * 10 * 8 + 40);        // 5 frames x 10 bits x 8 cycles, plus margin
check(rx_cnt, 4);             // RX FIFO is full with bytes 1-4
check(rx_pc, RX_PUSH);        // SM stalls on push, holding byte 5 in the ISR

// ---- Host reads: the stalled byte gets through ----
rx_get(b, 20);                // x5: read a byte; the first read frees a slot,
                              // so the stalled push completes
check(b, pattern[...]);       // all 5 bytes come out, in order
```

---

## 5. Does it catch bugs?

Each of these was put into a copy of the design or testbench, and the test failed every time:

| Bug | Caught by |
|---|---|
| RX ISR shifts left instead of right | Loopback: `0x55` came back as `0xAA` |
| OSR always shifts left | TX: `0x55` sent as `0xAA` |
| Delay one cycle short | TX: bit 0 lasted 7 cycles, not 8 |
| `jmp pin` always taken | Framing: the bad frame was pushed |
| `jmp pin` ignores `JMP_PIN` (reads GPIO 0) | Framing: the bad frame was pushed |

---

## 6. Things to look at in the waveform

Open `sim_outputs/modules/sv/sm_uart.fst` in GTKWave or Surfer and add:

| Signal | Shows |
|---|---|
| `tx_line`, `rx_line` | The UART line |
| `tx_pc`, `rx_pc` | Which instruction each SM is on |
| `tx_sm.osr_q`, `tx_sm.osr_cnt` | Bits left to send |
| `rx_sm.isr_q`, `rx_sm.isr_cnt` | Bits received so far |
| `tx_cnt`, `rx_cnt` | FIFO fill levels |
| `tx_pop`, `rx_push` | FIFO transfers |
| `irq_flags` | Flag 5 = framing error |

A good first look is one loopback frame at divisor 1: `rx_pc` should go 0 → 1, stay on 1 for the delay, then alternate 2 and 3 eight times, sampling `rx_line` in the middle of each bit.

---

## 7. Adding a test

1. Write a `task automatic test_<name>();`.
2. Start it with `reset_all(<div>)`, then change `loopback`, the configs or the programs if needed.
3. Enable one or both SMs (`en_tx`, `en_rx`, or `start()`).
4. Use `tx_put`, `rx_get`, `uart_frame`, `drive_frame` and `step`, and `check` the results.
5. Call the task from the `initial` block at the end of the file, before the `$display`.
