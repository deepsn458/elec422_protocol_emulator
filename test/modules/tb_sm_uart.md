# tb_sm_uart.sv: full-duplex UART on one state machine

`tb_sm_uart.sv` runs a UART on **one** `sm_no_smx_instr` (`DATA_WIDTH = 8`). The same state machine transmits on GPIO 6 and receives on GPIO 2 **at the same time** (full duplex). The testbench checks the TX waveform bit by bit, and the bytes that come out of the RX FIFO.

Run it from `test/`:

```bash
make sim_tb_sm_uart
```

It prints `SM UART SystemVerilog test passed`, or stops at the first failing check, naming what failed with the value it got and the value it expected. The waveform is written to `sim_outputs/modules/sv/sm_uart.fst`.

Icarus prints a few `sorry: constant selects in always_* processes` notices for `sm_no_smx_instr.sv`. They are harmless.

---

## 1. Setup

```
 tx_put()  (host writes a pre-framed byte as 4 FIFO words)
    |
    v
+---------+  tx_data, tx_empty, tx_level   +-------------------+
| TX FIFO | -----------------------------> |        dut        | <-- clk, rst, en
| 4 deep  | <----------------------------- |  sm_no_smx_instr  |
+---------+  tx_pop                        |  SM_ID = 0        |
                                           |  DATA_WIDTH = 8   |
+---------+  instr                         |                   |
|  imem   | -----------------------------> |                   |
| 64 x 16 | <----------------------------- |                   |
+---------+  mem_addr (next PC)            |                   |
                                           |                   |   pins_we/wdata, dirs_we/wdata
+---------+  rx_data, rx_push              |                   | ------------------+
| RX FIFO | <----------------------------- |                   |                   |
| 4 deep  | -----------------------------> |                   | <-- gpio_in --+   |
+---------+  rx_full, rx_level             +-------------------+               |   v
    |                                          |     ^                    +-------------+
    |  host_rx_re                    irq_set   |     | irq_flags          | GPIO models |
    v                                          v     |                    +-------------+
 rx_get()                                   +-----------+                   |         ^
                     host_irq_clr --------> | irq_flags |                   | GPIO 6  | GPIO 2
                                            +-----------+           tx_line |         | rx_line
                                                                            v         |
                                                       loopback = 1:  tx_line ---> mux
                                                       loopback = 0:  drv_line --> mux
```

| Item | Value | Why |
|---|---|---|
| `DATA_WIDTH` | 8 | X, Y, ISR, OSR, FIFO words and the GPIO bus are 8 bits. A pre-framed byte takes 4 TX FIFO words (section 2) |
| TX pin (`TXP`) | GPIO 6 | `SET_BASE`, `OUT_BASE` |
| RX pin (`RXP`) | GPIO 2 | `IN_BASE`, `JMP_PIN` |
| `SM_ID` | 0 | `irq 4 rel` sets flag 4 |
| Bit time | 12 SM cycles | 3 slots of 4 cycles |
| Clock divisor | `clkdiv` | Bit time in clocks = 12 × divisor |

### Memory and boot

`imem` holds the program at 0–31 and the config at 32–39 (CLKDIV, EXECCTRL, SHIFTCTRL, PINCTRL, low half first). After `rst` falls, the SM reads 32–39 into its config registers in 8 cycles, then starts at address 0. `reset_all` writes everything and waits out the boot.

| Config | Value |
|---|---|
| PINCTRL | `SET_COUNT = 1`, `SET_BASE = 6`, `OUT_COUNT = 1`, `OUT_BASE = 6`, `IN_BASE = 2`, no side-set |
| EXECCTRL | `JMP_PIN = 2`, wrap 28 → 26 |
| SHIFTCTRL | `PULL_THRESH = 8`, `PUSH_THRESH = 8`, OUT and IN shift right, no autopull/autopush |

### Pins and roles

- A pin nothing drives reads **high**, like a UART line with a pull-up.
- `tx_line` is GPIO 6. `rx_line` is GPIO 2: `tx_line` when `loopback = 1`, otherwise `drv_line`.
- The testbench plays two roles, and they never mix:
  - As the **host**, it only touches the FIFOs and IRQ flags (`tx_put`, `rx_get`, `host_irq_clr`).
  - As the **external device** on the other end of the wire, it only touches `drv_line` (`drive_frame`) and watches `tx_line` (`uart_frame`).

---

## 2. How one SM does both directions

### Why not just "out, then in" every bit

A loop like `out pins, 1 [d]` / `in pins, 1 [d]` puts the RX samples at fixed points on the **TX** bit grid. That only works if the other device's bits happen to line up with ours. A real device can start its frame at any moment, so a fixed sample point can land right on a bit edge and read garbage. RX has to line up with **its own** start bit, while TX keeps its own steady timing. One program has to do both.

### Slots

Each UART bit is split into **3 slots of 4 cycles**. Every slot starts with the same two TX instructions, and the rest of the slot is one RX step:

```
cycle:   0                       1              2              3
       | pull ifempty noblock  | out pins, 1  | RX step      | (RX step or delay) |
         TX: next word if used   TX: 1/3 bit    poll / sample / count / check
```

Because **every** slot does identical TX work, the RX code can begin a frame in any slot, and TX timing is unaffected. RX lines up to its start bit to within one slot.

### What that costs: pre-framed TX words

`out pins, 1` runs every slot, so it sends **one third of a bit** each time. The host therefore pre-frames each byte: start bit, 8 data bits (LSB first), stop bit, **each repeated 3 times** = 30 bits, padded with two 1s to 32 (`frame_word`). That 32-bit value goes into the 8-bit TX FIFO as **4 words, low byte first**.

```
frame_word(0x96), bit 31 on the left:
  11  111  111  000  000  111  000  111  111  000  000
  --  stop  d7   d6   d5   d4   d3   d2   d1   d0  start
padding
  |------ word 3 ------|----- word 2 -----|---- word 1 ----|-- word 0 --|
  (word boundaries every 8 bits from the right; word 0 is written first)
```

- `PULL_THRESH = 8`, so `pull ifempty` fetches the next word after 8 `out`s. Four words make one frame plus 2 padding slots, so back-to-back frames are separated by 2/3 of a bit of extra idle (a slightly long stop bit, which any UART accepts).
- **The host must write all 4 words of a frame together, and only into an empty FIFO** (`tx_put` does this). The FIFO is 4 deep, so a whole frame is queued before the SM needs its second word. If the host wrote only part of a frame, `pull noblock` would find the FIFO empty mid-frame and send 8 idle bits in the middle of the frame.
- The host can queue the next frame as soon as the FIFO is empty, which happens when the SM pulls word 3. Word 3 still has 8 slots (2.7 bits) to send, so the host has that long to write the next 4 words and keep frames back to back.
- If the TX FIFO is empty, `pull noblock` copies **X** into the OSR instead. X holds all ones (`mov x, ~null`), so the line sends 10 idle-high bits, then checks the FIFO again.
- Everything else is 8-bit friendly: RX receives 8 bits into an 8-bit ISR (`PUSH_THRESH = 8`), `set y, 7` counts bits, and `mov x, ~null` gives `0xFF`.

### RX timing

The idle loop checks the RX line once per slot. When it sees a start bit, the edge happened sometime in the last 4 cycles. RX then samples:

| Sample | When (after the slot that saw the start) | Where in the bit |
|---|---|---|
| Data bit 0 | 4 slots = 16 cycles | 33%–67% of the way through |
| Data bits 1–7 | every 3 slots = 12 cycles after that | same |
| Stop bit | 3 slots after bit 7 | same |

So every sample lands in the middle third of its bit, whatever the phase of the incoming frame. Test 3 drives a frame at every possible cycle offset to prove it.

### Nothing blocks

A stalled instruction would freeze **both** directions, so every instruction is non-blocking: `pull ... noblock` and `push ... noblock`. The testbench counts stall cycles and requires 0 in every test.

---

## 3. The program

29 instructions. "P" is `pull ifempty noblock` and "O" is `out pins, 1`, the TX pair at the start of every slot.

| Addr | Instruction | Hex | Part |
|---|---|---|---|
| 0 | `set pins, 1` | E001 | Init: line high... |
| 1 | `set pindirs, 1` | E081 | ...then make it an output (no glitch) |
| 2 | `mov x, ~null` | A02B | X = all ones, the idle word |
| 3 | `push iffull noblock` | 8040 | Good frame: push the byte |
| 4 | P | 80C0 | **Idle slot** |
| 5 | O | 6001 | |
| 6 | `jmp pin 4 [1]` | 01C4 | Line high: stay idle. Low: start bit |
| 7 | P | 80C0 | **Filler slot** |
| 8 | O | 6001 | |
| 9 | `set y, 7 [1]` | E147 | Bit counter |
| 10 | P | 80C0 | **Bit loop**, slot 1 |
| 11 | `out pins, 1 [2]` | 6201 | |
| 12 | P | 80C0 | Slot 2 |
| 13 | `out pins, 1 [2]` | 6201 | |
| 14 | P | 80C0 | Slot 3 |
| 15 | O | 6001 | |
| 16 | `in pins, 1` | 4001 | Sample the bit |
| 17 | `jmp y-- 10` | 008A | 8 data bits |
| 18–21 | P, `out [2]`, P, `out [2]` | | **Stop bit**, slots 1–2 |
| 22 | P | 80C0 | Slot 3 |
| 23 | O | 6001 | |
| 24 | `jmp pin 3` | 00C3 | Stop bit high: go push |
| 25 | `irq 4 rel` | C014 | Stop bit low: framing error |
| 26 | P | 80C0 | **Wait-high slot** (wrap bottom) |
| 27 | O | 6001 | |
| 28 | `jmp pin 4 [1]` | 01C4 | High: back to idle. Low: wrap to 26 (wrap top) |

### Init (0–3)

- `set pins, 1` then `set pindirs, 1`: drive the TX pin high **before** making it an output, so the remote device never sees a false start bit.
- `mov x, ~null`: `mov` copies a source into a destination. Destination `x`, source `null` (all zeros), operation `~` (invert), so X = all ones. `pull noblock` copies X when the FIFO is empty, which makes the line idle high.
- Address 3 (`push iffull noblock`) is also where a good frame ends up. At init the ISR is empty, so `iffull` makes it do nothing, and execution falls into the idle slot.

### Idle slot (4–6)

- `pull ifempty noblock`: `ifempty` means only pull when the OSR has used up `PULL_THRESH = 8` bits; otherwise it does nothing. `noblock` means that if the TX FIFO is empty it copies X instead of stalling.
- `out pins, 1`: shift 1 bit out of the OSR onto the OUT pins (GPIO 6).
- `jmp pin 4 [1]`: `pin` jumps if the `JMP_PIN` (GPIO 2) is **high**. High means no start bit, so loop back to 4. Low falls through to the filler slot. `[1]` pads the slot to 4 cycles. The delay applies whether or not the jump is taken, so both paths take the same time.

### Filler slot (7–9)

One slot between seeing the start bit and the bit loop, so that the first sample lands 4 slots later. `set y, 7` loads the bit counter: `jmp y--` jumps while Y is nonzero (before decrementing), so the loop runs 8 times.

### Bit loop (10–17)

Three slots per bit. Slots 1 and 2 are just TX (`out pins, 1 [2]` pads them to 4 cycles). Slot 3 does TX, then:

- `in pins, 1`: shift 1 bit from the IN pins (GPIO 2) into the ISR. IN shifts right, so after 8 bits the ISR (8 bits wide) holds the byte, LSB in bit 0.
- `jmp y-- 10`: back to slot 1 for the next bit, 8 times in total.

### Stop bit (18–25)

Two TX-only slots, then in slot 3 `jmp pin 3` checks the stop bit at the same point in the bit as the data samples.

- **High** (good frame): jump to address 3. `push iffull noblock` pushes the ISR to the RX FIFO. `iffull` is true because the ISR has `PUSH_THRESH = 8` bits. `noblock` means that if the RX FIFO is full the byte is dropped instead of stalling, because a stall would also stop TX. Then idle.
- **Low** (framing error): `irq 4 rel` sets IRQ flag 4 + `SM_ID` = 4. Nothing is pushed. The leftover 8 bits in the ISR are harmless: the next good frame shifts in 8 more, which push them out of the 8-bit ISR, and then pushes.

### Wait-high slot (26–28)

After a framing error the line may stay low (a break). Going straight back to idle would see "start bits" over and over. This slot checks for the line going high: `jmp pin 4` goes back to idle when it is high, and the wrap (28 → 26) loops here while it is low, at no cost. TX keeps running the whole time.

### Full memory image (hex)

These are the 40 16-bit words the testbench loads into `imem` (dumped from the simulation, clock divisor 1). Addresses 0–31 are the program, 32–39 are the config the SM loads at boot (low half first). It is in `$readmemh` format: one word per line, in address order starting at 0, and `//` comments are ignored.

```
// ---- program (0-31) ----
E001  // 0   set pins, 1
E081  // 1   set pindirs, 1
A02B  // 2   mov x, ~null
8040  // 3   push iffull noblock
80C0  // 4   pull ifempty noblock       (idle slot)
6001  // 5   out pins, 1
01C4  // 6   jmp pin 4 [1]
80C0  // 7   pull ifempty noblock       (filler slot)
6001  // 8   out pins, 1
E147  // 9   set y, 7 [1]
80C0  // 10  pull ifempty noblock       (bit loop, slot 1)
6201  // 11  out pins, 1 [2]
80C0  // 12  pull ifempty noblock       (slot 2)
6201  // 13  out pins, 1 [2]
80C0  // 14  pull ifempty noblock       (slot 3)
6001  // 15  out pins, 1
4001  // 16  in pins, 1
008A  // 17  jmp y-- 10
80C0  // 18  pull ifempty noblock       (stop bit, slot 1)
6201  // 19  out pins, 1 [2]
80C0  // 20  pull ifempty noblock       (slot 2)
6201  // 21  out pins, 1 [2]
80C0  // 22  pull ifempty noblock       (slot 3)
6001  // 23  out pins, 1
00C3  // 24  jmp pin 3
C014  // 25  irq 4 rel
80C0  // 26  pull ifempty noblock       (wait-high slot, wrap bottom)
6001  // 27  out pins, 1
01C4  // 28  jmp pin 4 [1]              (wrap top)
001D  // 29  jmp 29                     (unused, never reached)
001E  // 30  jmp 30                     (unused, never reached)
001F  // 31  jmp 31                     (unused, never reached)
// ---- config (32-39), loaded at boot ----
0000  // 32  CLKDIV[15:0]     FRAC = 0
0001  // 33  CLKDIV[31:16]    INT = 1
CD00  // 34  EXECCTRL[15:0]   WRAP_TOP = 28, WRAP_BOTTOM = 26
0201  // 35  EXECCTRL[31:16]  JMP_PIN = 2
0000  // 36  SHIFTCTRL[15:0]
108C  // 37  SHIFTCTRL[31:16] PULL_THRESH = 8, PUSH_THRESH = 8, OUT/IN shift right
00C6  // 38  PINCTRL[15:0]    IN_BASE = 2, SET_BASE = 6, OUT_BASE = 6
0411  // 39  PINCTRL[31:16]   SET_COUNT = 1, OUT_COUNT = 1
```

Only addresses 32 and 33 change with the clock divisor:

| Divisor | 32 (`CLKDIV[15:0]`) | 33 (`CLKDIV[31:16]`) |
|---|---|---|
| 1 | 0000 | 0001 |
| 3 | 0000 | 0003 |
| 2.5 | 8000 | 0002 |

---

## 4. Testbench pieces

### Models

| Model | What it does |
|---|---|
| `imem` | 64 × 16-bit instruction memory with a synchronous read, like the IHP SRAM: `instr <= imem[mem_addr]` on each clock edge (when `read_en`). `mem_addr` is the SM's next PC, so `instr` is the word at the current PC (`dut.pc`) |
| TX FIFO | 4 deep, first-word fall-through, written by `tx_put()` |
| RX FIFO | 4 deep, read by `rx_get()` |
| IRQ flags | 8 flags, set by the SM, cleared by the SM or the host (write 1 to clear) |
| `gpio_out` / `gpio_oe` | Pin levels and directions, updated from the SM's write masks |
| `stalls` | Counts cycles where an instruction was stalled; must stay 0 |
| `both_low` | Counts cycles where `tx_line` and `drv_line` are both low, proof that TX and RX frames overlapped |

### Helpers

| Task / function | What it does |
|---|---|
| `prog(a)` / `prog_hex(a)` | The program built with encoders, and the same program hand-assembled |
| `frame_word(b)` | The host's 32-bit pre-framed value for byte `b` (30 frame bits + 2 padding) |
| `reset_all(div)` | Reset, load program and config into `imem`, boot. `div` is 16.8 fixed point: `24'h0100` = 1, `24'h0280` = 2.5. SM left disabled |
| `tx_put(b)` | Waits until the TX FIFO is empty, then writes the 4 bytes of `frame_word(b)` on 4 consecutive cycles |
| `rx_get(b, max)` | Host reads a word (the received byte) from the RX FIFO, waiting up to `max` cycles |
| `uart_frame(bit_cycles, data, idle)` | External device watches `tx_line`: waits for a start bit, checks every bit lasts exactly `bit_cycles`, start = 0 and stop = 1, returns the byte and the idle cycles before it |
| `drive_frame(data, bit_cycles, stop)` | External device sends a frame on `drv_line`. `stop = 0` makes a bad stop bit. The line stays at the stop level afterwards |
| `in_idle(pc)`, `in_waithigh(pc)` | Is the PC in the idle slot (4–6) or the wait-high slot (26–28)? |
| `check(got, exp, what)` | Stops the simulation with `$fatal` if `got != exp` |

Inputs change and checks happen 1 ns after the rising edge, the same as the other state machine testbenches.

Test bytes: `pattern` = `55 00 FF 01 80 A5 3C C3` for TX, `other` = `96 69 F0 0F 7E 81 33 CC` for the external device. Alternating bits, all zeros, all ones and single end bits make a wrong shift direction or a dropped bit show up.

---

## 5. The tests

7 tests, run 13 times in total ([tb_sm_uart.sv:668](tb_sm_uart.sv)):

| Test | Runs |
|---|---|
| 1. Program | once |
| 2. TX | divisors 1, 3 |
| 3. RX at every phase | divisors 1, 3 |
| 4. Full duplex | divisors 1, 3 |
| 5. Loopback | divisors 1, 3, 2.5 |
| 6. Framing error | divisors 1, 2 |
| 7. RX FIFO full | divisor 1 |

### 1. Program (`test_program`)

Code: `tb_sm_uart.sv` lines 488–495.

Checks that the encoders in `prog()` build exactly the hand-assembled words in `prog_hex()`, and that `frame_word(0x96)` has the layout shown in section 2.

### 2. TX (`test_tx`, divisors 1 and 3)

Code: `tb_sm_uart.sv` lines 499–527.

```
 tx_put(pattern[i])
    |
    v
+---------+         +-------------------+  GPIO 6, tx_line   +--------------+
| TX FIFO | ------> |        dut        | -----------------> | uart_frame() |
+---------+         | RX line held high |                    | decodes byte |
                    +-------------------+                    | times bits   |
                                                             +--------------+
```

```systemverilog
reset_all(div << 8);          // reset, load, boot; SM off
loopback = 0;                 // RX line = drv_line, held high: no RX traffic
en = 1;
step(2 * div);                // runs set pins, set pindirs
check(gpio_oe, 1 << TXP);     // GPIO 6 is an output, no other pin is
check(tx_line, 1);            // idles high
step(40 * div);
check(tx_line, 1);            // still high: X (all ones) is being sent

fork                          // tx_put waits for an empty FIFO, so run host and watcher together
  tx_put(pattern[i]);         // x8: host writes each frame as 4 words
  uart_frame(12 * div, b, idle);// x8: decode each frame; every bit exactly 12 * div clocks
  check(b, pattern[i]);       // byte on the wire == byte written
  check(idle, 1 + 8 * div);   // bytes 2-8: only the 2 padding slots between frames
join

step(30 * div);
check(tx_line, 1);            // back to idle high
check(rx_cnt, 0);             // RX received nothing (line was idle)
check(irq_flags, 0);
check(gpio_oe, 1 << TXP);     // directions unchanged
check(stalls, 0);             // never stalled
```

### 3. RX at every phase (`test_rx_phases`, divisors 1 and 3)

Code: `tb_sm_uart.sv` lines 531–550.

```
 drive_frame(other[off % 8])   <- external device, starting `off` cycles later each time
    |
    | drv_line -> mux (loopback = 0) -> GPIO 2
    v
+-------------------+
|        dut        | ---> tx_line: check still idle high
+-------------------+
    |
    v
+---------+
| RX FIFO | ---> rx_get(b): check b == other[off % 8]
+---------+
```

This is the test that a fixed-grid "out then in" design would fail. One bit is `12 * div` clocks, and the test sends a frame starting at **every** clock offset within a bit, so every possible alignment between the incoming frame and the SM's slots is covered.

```systemverilog
reset_all(div << 8);
loopback = 0;                 // testbench drives the RX line
en = 1;
step(5);
for (off = 0; off < 12 * div; off++) begin
    step(off);                // shift the start time by one more clock
    drive_frame(other[off % 8], 12 * div, 1);
    rx_get(b, 4 * 12 * div);
    check(b, other[off % 8]); // received correctly at this phase
end
check(rx_cnt, 0);             // no extra bytes
check(irq_flags, 0);          // no framing errors
check(tx_line, 1);            // TX stayed idle
check(stalls, 0);
```

### 4. Full duplex (`test_full_duplex`, divisors 1 and 3)

Code: `tb_sm_uart.sv` lines 554–593.

```
 host_tx: tx_put(pattern[0..7])            device_tx: drive_frame(other[0..7])
    |                                          |  (starts 7 cycles in, extra
    v                                          |   0..7 cycles between frames)
+---------+     +-------------------+          v
| TX FIFO | --> |        dut        | <-- GPIO 2 (drv_line)
+---------+     +-------------------+
                   |             |
          GPIO 6   |             v
                   v        +---------+
   watch_tx: uart_frame()   | RX FIFO | --> host_rx: rx_get(), check == other[i]
   check == pattern[i]      +---------+
```

Four threads run at once (`fork ... join`). The two directions have unrelated timing, and the external device's frame phase changes from frame to frame.

```systemverilog
reset_all(div << 8);
loopback = 0;
en = 1;
step(5);
fork
    host_tx:   tx_put(pattern[i])               x8
    watch_tx:  uart_frame(); check(b, pattern[i])  x8   // exact timing, every bit
    device_tx: step(7); drive_frame(other[i]); step(i)  x8
    host_rx:   rx_get(b); check(b, other[i])     x8
join
check(both_low > 10 * 12 * div);  // the two directions really overlapped
check(irq_flags, 0);
check(stalls, 0);
```

### 5. Loopback (`test_loopback`, divisors 1, 3 and 2.5)

Code: `tb_sm_uart.sv` lines 596–613.

```
 tx_put(pattern[i]) --> TX FIFO --> dut --GPIO 6--> mux (loopback = 1) --GPIO 2--> dut --> RX FIFO --> rx_get(b)
```

The SM receives its own transmission. At divisor 2.5 the SM ticks every 2 or 3 clocks, so bits are not all the same length in clocks. This checks the slot timing with a fractional divider.

```systemverilog
reset_all(div);               // loopback = 1
en = 1;
tx_put(pattern[...]);         // x4, two groups
rx_get(b, ...);               // x4
check(b, pattern[...]);       // received == sent
step(...);
check(rx_cnt, 0);             // no extra bytes
check(irq_flags, 0);          // no framing error
check(in_idle(pc), 1);        // RX back in the idle slot
check(stalls, 0);
```

### 6. Framing error (`test_rx_framing`, divisors 1 and 2)

Code: `tb_sm_uart.sv` lines 617–654.

```
 drive_frame(.., stop)  <- external device
    |
    | GPIO 2
    v
+-------------------+  irq_set, flag 4   +-----------+
|        dut        | -----------------> | irq_flags | <-- host_irq_clr
+-------------------+                    +-----------+
    |          |
    |          +--> GPIO 6: tx_put(0xA5) during the break, uart_frame() checks it
    v
+---------+
| RX FIFO | --> nothing pushed for the bad frame
+---------+
```

```systemverilog
reset_all(div << 8);
loopback = 0;
en = 1;
step(5);
drive_frame(8'h96, bc, 1);    // good frame
rx_get(b); check(b, 8'h96);

drive_frame(8'h00, bc, 0);    // stop bit low; line stays low (a break)
step(2 * bc);
check(rx_cnt, 0);             // bad frame not pushed
check(irq_flags, 1 << 4);     // flag 4 set by irq 4 rel
check(in_waithigh(pc), 1);    // waiting for the line to go high
tx_put(8'hA5);                // TX still works during the break
uart_frame(bc, b, idle); check(b, 8'hA5);
check(in_waithigh(pc), 1);    // still waiting
check(rx_cnt, 0);             // no phantom frames

drv_line = 1;                 // break ends
step(bc);
check(in_idle(pc), 1);        // back to idle
host_irq_clr = 1 << 4;        // host clears flag 4 (write 1 to clear)
step(1); host_irq_clr = 0; step(1);
check(irq_flags, 0);

drive_frame(8'h69, bc, 1);    // good frame after the error
rx_get(b); check(b, 8'h69);
check(irq_flags, 0);          // no new error
check(stalls, 0);
```

### 7. RX FIFO full (`test_rx_fifo_full`)

Code: `tb_sm_uart.sv` lines 658–677.

```
 tx_put() x6 --> TX FIFO --> dut --loopback--> dut --> RX FIFO (holds 4; bytes 5, 6 dropped)
                                                          |
                                                          v  nothing read until the end
```

`push noblock` drops a byte when the RX FIFO is full, instead of stalling and stopping TX.

```systemverilog
reset_all(24'h0100);          // divisor 1, loopback
en = 1;
tx_put(pattern[...]);         // x6, host doesn't read
step(...);                    // all 6 frames go out
check(rx_cnt, 4);             // FIFO full with bytes 1-4
check(tx_cnt, 0);             // TX sent all 6: it never stopped
check(stalls, 0);
rx_get(b); check(b, pattern[...]);  // x4: bytes 1-4 in order
check(rx_cnt, 0);             // bytes 5 and 6 were dropped
tx_put(8'h3C);
rx_get(b); check(b, 8'h3C);   // receiving works again
```

---

## 6. Does it catch bugs?

Each of these was put into a copy of `sm_no_smx_instr.sv`, and the test failed every time:

| Bug in the SM | Caught by |
|---|---|
| `pull noblock` doesn't copy X when the FIFO is empty | TX: line not idle high |
| `push iffull` ignores the threshold | TX: init pushed an empty word |
| `jmp pin` ignores `JMP_PIN` (reads GPIO 0) | RX: no byte received |
| IN ignores `IN_BASE` | RX: byte read as `0xFF` |
| `pull ifempty` always pulls | TX: bit 1 changed after 4 of 12 cycles |

---

## 7. Things to look at in the waveform

Open `sim_outputs/modules/sv/sm_uart.fst` and add:

- `tb_sm_uart.dut.pc`: idle (4–6), filler (7–9), bit loop (10–17), stop (18–25), wait-high (26–28).
- `tb_sm_uart.tx_line` and `tb_sm_uart.rx_line`: the two wires.
- `tb_sm_uart.dut.osr_q`, `tb_sm_uart.dut.osr_cnt`: the TX word shifting out, and the count reaching 8 every 8 slots (4 words per frame).
- `tb_sm_uart.dut.isr_q`, `tb_sm_uart.dut.y`: RX bits arriving, and the bit counter.
- `tb_sm_uart.tx_pop`, `tb_sm_uart.rx_push`, `tb_sm_uart.irq_flags`.

---

## 8. Limits of this design

- **Same baud rate both ways.** TX and RX share the slot timing, so both directions run at 12 SM cycles per bit.
- **RX accuracy.** Samples land 33–67% of the way through each bit. That is plenty for a clean line and normal clock mismatch, but it's coarser than a 16× oversampling UART.
- **Host does the framing.** The host must send `frame_word(b)` as 4 FIFO words, not the raw byte. It must write all 4 together into an empty FIFO, so only one byte can be queued at a time and TX uses 4 FIFO words per byte.
- **2 padding slots per frame.** TX throughput is 10.67 bit times per byte instead of 10.
- **Full RX FIFO drops bytes** instead of stalling, because a stall would also stop TX.

---

## 9. Adding a test

1. Write a `task automatic test_<name>()` that starts with `reset_all(div)`, sets `loopback`, and sets `en = 1`.
2. Drive bytes with `tx_put` / `drive_frame`, observe them with `uart_frame` / `rx_get`, and use `check` for everything.
3. End with `check(stalls, 0, ...)`.
4. Call it from the `initial` block before the "passed" message.
