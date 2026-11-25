# Integration: SM to each neighbouring module

## Test objective

`pio_spi_top` connects `sm_no_smx_instr` directly to four modules:
- the instruction SRAM;
- the TX FIFO;
- the RX FIFO;
- the GPIO controller.

Each testbench below takes the **real SM and one real module**, connected exactly as in `pio_spi_top`, and checks that one connection on its own. Every other port is a simple testbench model or tied off. When a test fails, the problem is in that connection.

`tb_imem_to_gpio` (all blocks together, running the SM's functional tests) and `tb_pio_spi_top` (the whole chip over SPI) build on these.

The SM's other two connections have no testbench here:
- **IRQ flags:** a 3-line register inside `pio_spi_top`, covered by `tb_imem_to_gpio`'s `test_irq`.
- **`spi_slave`:** it only reaches the SM through `loaded` → `imem_loaded`, covered by `tb_spi_imem_sm`.

## How to run

From `test/`:

```
make sim_int_sm_imem
make sim_int_sm_tx_fifo
make sim_int_sm_rx_fifo
make sim_int_sm_gpio
```

Each run prints `... integration test passed`, or stops with `$fatal` and the number of failed checks, so `make` fails too. Every failed check is printed as an `ERROR` line first.

## Common setup

- `DATA_WIDTH = 16` and `FIFO_DEPTH = 4`, as in `pio_spi_top`.
- Programs are hand-encoded with the encoders in `sm_tb_common.svh`, so these tests don't depend on the assembler.
- The SM boots from its config words at 32–39, like on the chip.
- Except in `tb_sm_imem`, the instruction memory is a testbench model with a synchronous read gated by `read_en`, which behaves like the SRAM.

## The testbenches

| Testbench | Connection | Checked every cycle | Scenarios |
|---|---|---|---|
| `tb_sm_imem.sv` | SM ↔ IHP SRAM model (`mem_addr`, `read_en`, `instr`, `imem_loaded`) | `instr` equals `memory[pc]` whenever the SM is out of reset, boot included | load through the SRAM write port with the SM held at 32; release one cycle after `loaded`; boot 32→39→0 with matching config; a PC trace for increment, JMP taken and not taken, MOV PC, OUT PC and 31→0; wrap; holds (stalled PULL, delay cycles, en low); clock divisor 3 and 2.5; SM_RESTART doesn't reboot; rst and reload with a different image |
| `tb_sm_tx_fifo.sv` | SM ↔ TX `fifo.sv` (`tx_data = head`, `tx_empty`, `tx_level`, `tx_pop`) | scoreboard: each pop returns the oldest word written, never pops an empty FIFO, and the FIFO level matches the model | PULL block (stalls, completes the cycle after the write); PULL noblock (copies X, no pop); PULL ifempty; autopull at thresholds 16 and 8; 4 pops on consecutive cycles; writes beyond depth 4 dropped; `mov x, status` against `tx_level` |
| `tb_sm_rx_fifo.sv` | SM ↔ RX `fifo.sv` (`rx_data`, `rx_push`, `rx_full`, `rx_level`) | scoreboard: never pushes into a full FIFO, host reads come back in order, and the level matches the model | PUSH block (stalls on full, completes the cycle after a host pop); PUSH noblock (dropped on full, ISR cleared); PUSH iffull; autopush at thresholds 16 and 8 (IN stalls on full); `mov x, status` against `rx_level` |
| `tb_sm_gpio.sv` | SM ↔ `gpio_controller` (`pins_we/wdata`, `dirs_we/wdata`, `pins_re`, `gpio_in`, `gpio_fault`) | pin registers follow the SM's write masks, and nothing changes on a fault cycle or while faulted; `gpio_in` is the readable pads; no unexpected fault | SET, OUT and MOV to pins and pindirs; side-set to pins and to pindirs; IN, WAIT GPIO, WAIT PIN and JMP PIN reads; `mov x, pins` reads output-only pins as 0; three faults (described below) |

The three faults in `tb_sm_gpio` are: driving an input pin, setting the direction of an output-only pin, and reading an output-only pin from a stalled WAIT. For each, the test checks that:
- the PC branches to FAULT_VEC that same cycle;
- no write lands that cycle;
- bidirectional pads are released, and output pads go to SAFE_OUT;
- `fault_cause` is correct;
- the handler's writes are ignored until `clr_fault`.

## Test by test

Each testbench's every-cycle monitor runs through all of its tests. The tables say what each test adds on top of that, and which bug it would catch.

### `tb_sm_imem`: SM ↔ instruction SRAM

The monitor checks `instr == memory[pc]` on every cycle the SM is out of reset. Each test drives a different source of "which address does the SRAM read next".

| Test | What it covers | Bug it would catch |
|---|---|---|
| `load_and_boot` (runs at the start of every test) | memory is written through the SRAM's write port while the SM is held at 32; the SRAM switches over to the SM when `loaded` rises; boot reads 32–39 and the config registers match | the first config word not ready when reset ends (`read_en` low during reset), or the SM starting before the load finishes |
| `test_pc_moves` | every way the PC moves: +1, JMP taken, JMP not taken, MOV PC, OUT PC, 31 → 0 (wrap off). The trace must be 0, 1, 3, 4, 5, 7, 8, 9, 29, 30, 31, 0, 1, 3 | one kind of PC change sending the wrong next address to the SRAM, so the instruction after that jump is wrong; or 31 stepping into the config words |
| `test_wrap` | the PC jumps back from `WRAP_TOP` (3) to `WRAP_BOTTOM` (1) with no jump instruction | the wrap jump not sending the right next address to the SRAM |
| `test_holds` | the PC **doesn't** move: a stalled `pull`, delay cycles (`nop [3]` completes once every 4 cycles), `en` low | the next address moving ahead while the PC holds, so the SRAM returns the wrong word when the SM resumes |
| `test_clkdiv` (divisors 3 and 2.5) | instructions run only on divider ticks, so the PC holds between ticks, including the uneven gaps of 2.5. Checks the number of instructions in 30 cycles | the same holding problem, caused by the divider rather than the program; or the divider not loaded from the config words |
| `test_restart` | a `restart` pulse mid-program | `restart` rebooting the SM, sending it back to 32 and reloading the config |
| `test_reload` | `rst`, then a different program and config (wrap 1 → 0) loaded and run | a stale word or the old config used after reloading. On the chip this is how the host loads a new program |

### `tb_sm_tx_fifo`: SM ↔ TX FIFO

The scoreboard checks every pop: the oldest word, never from an empty FIFO, and the FIFO level matches.

| Test | What it covers | Bug it would catch |
|---|---|---|
| `test_pull_block` | `pull block` on an empty FIFO stalls, then completes exactly one cycle after the host writes, with that word in the OSR | not stalling (pulling garbage), never waking up, or taking the word a cycle late (the old FIFO output timing bug) |
| `test_pull_noblock` | `pull noblock` on an empty FIFO copies X into the OSR and doesn't pop | popping an empty FIFO, or loading something other than X |
| `test_pull_ifempty` | `pull ifempty` (threshold 8) is a no-op after 4 bits, and pulls after 8 | `tx_level`/threshold wiring wrong, so it pulls too early or too late |
| `test_autopull_16` | autopull at threshold 16: `out` stalls on an empty FIFO and continues when the host writes | `out` running on an empty OSR, or not refilling |
| `test_autopull_8` | autopull at threshold 8: each 16-bit word supplies only its low 8 bits before the next pop | the pull threshold ignored, so both `out`s come from one word |
| `test_back_to_back` | four `pull`s pop on four consecutive cycles, in order | the FIFO's head lagging when popped every cycle, giving repeated or skipped words |
| `test_overflow` | the host writes 5 words into a 4-deep FIFO: the 5th is dropped, the SM gets exactly 4, and a 5th `pull` stalls | the FIFO accepting a write when full (overwriting), or the SM seeing a word that isn't there |
| `test_status` (STATUS_N 2 and 4) | `mov x, status` with STATUS_SEL = TX, for every level 0–4 | `tx_level` miswired or off by one |

### `tb_sm_rx_fifo`: SM ↔ RX FIFO

The scoreboard checks every push and host read: never into a full FIFO, words come back in order, and the FIFO level matches.

| Test | What it covers | Bug it would catch |
|---|---|---|
| `test_push_block` | 5 `push block`s: 4 fill the FIFO, the 5th stalls, then completes exactly one cycle after the host pops; words come back 2, 3, 4, 5 | pushing into a full FIFO (lost data), never waking up, or waking a cycle late |
| `test_push_noblock` | the 5th `push noblock` on a full FIFO is dropped, the SM doesn't stall, and the ISR is still cleared | stalling on noblock, overwriting a full FIFO, or leaving stale bits in the ISR |
| `test_push_iffull` | `push iffull` (threshold 8) is a no-op at 4 bits and pushes at 8; the word is `3300` (IN shifts right) | the push threshold ignored, or the wrong ISR value pushed |
| `test_autopush_16` | autopush every 16 bits; with the FIFO full, `in` stalls until the host pops | `in` running when the FIFO is full (lost data), or not resuming |
| `test_autopush_8` | autopush every 8 bits: words `0500` and `0600` | the push threshold ignored, or the wrong part of the ISR pushed |
| `test_status` (STATUS_N 2 and 4) | `mov x, status` with STATUS_SEL = RX, for every level 0–4 | `rx_level` miswired or off by one (this testbench caught that bug) |

### `tb_sm_gpio`: SM ↔ GPIO controller

The monitor checks that pin registers follow the SM's writes exactly, that nothing changes during a fault, that `gpio_in` shows the readable pads, and that there are no unexpected faults.

| Test | What it covers | Bug it would catch |
|---|---|---|
| `test_set` | `set pindirs` / `set pins` on GPIO 4–8 (SET_BASE 4, count 5) | SET mapped to the wrong pins, or other bidirectional pins changed |
| `test_out_mov` | `out pins` (OSR bits → GPIO 10–13) and `mov pins, ~null` on a mix of bidirectional and output-only pins | wrong OUT base/count, bits in the wrong order, or writes leaking to GPIO 14–15 |
| `test_sideset` | side-set to pins (GPIO 12–13) and to pindirs (GPIO 6–7) | side-set bits mapped wrong, or SIDE_PINDIR ignored |
| `test_in` | `in pins, 4` from GPIO 2–5 (input-only and bidirectional) gives `B000` | IN_BASE ignored, or readable pins masked out |
| `test_wait` (GPIO and PIN) | `wait 1 gpio 3` and `wait 1 pin 1` (IN_BASE 2) stall until GPIO 3 rises; `pins_re` names GPIO 3 | the wait reading the wrong pin, or `pins_re` wrong (causing false faults) |
| `test_jmp_pin` (high and low) | `jmp pin` with JMP_PIN 9 takes the jump only when GPIO 9 is high | JMP_PIN ignored or miswired |
| `test_mov_pins` | `mov x, pins` reads all 16 pins: output-only pins read 0, no fault | output pins leaking into reads, or `mov pins` raising a false fault |
| `test_fault` ×3: drive an input pin, set direction on an output pin, read an output pin from a stalled `wait` | for each: PC → FAULT_VEC that cycle, no write lands, bidirectional pads released and outputs at SAFE_OUT, correct `fault_cause`, the handler's writes ignored until `clr_fault`, then normal operation | no fault branch, the bad write landing on the fault cycle (this testbench caught both), a stall winning over the fault, or `clr_fault` not recovering |

## Does it catch bugs?

Each bug below was put into a scratch copy of the RTL, one at a time, and the matching testbench failed every time.

| Bug | Caught by |
|---|---|
| `mem_addr` = current PC (the old fetch timing) | `tb_sm_imem`: instr ≠ memory[pc] |
| `read_en` low during reset | `tb_sm_imem`: SRAM not reading 32 at release |
| FIFO `head` registered (the old FIFO timing bug) | `tb_sm_tx_fifo`: popped the wrong word |
| PULL pops an empty FIFO | `tb_sm_tx_fifo`: pop on an empty FIFO |
| SM ignores `rx_full` | `tb_sm_rx_fifo`: push into a full FIFO |
| `rx_level` off by one in MOV STATUS | `tb_sm_rx_fifo`: status mismatch |
| no FAULT_VEC branch | `tb_sm_gpio`: PC not at FAULT_VEC |
| GPIO controller lets the fault cycle's writes land | `tb_sm_gpio`: write landed on the fault cycle |

## Limits

- **A fault can only come from the instruction the SM is running.** During delay cycles nothing is active, so nothing reaches the GPIO controller. So the case "a fault during a delay" can't happen with the real controller. The fault on a *stalled* WAIT is tested instead.
- **Exact same-cycle collisions at full aren't timed:** for example, a host write on exactly the cycle the SM pops from a full TX FIFO. The scoreboards still check every cycle, so any collision that does happen is checked.
