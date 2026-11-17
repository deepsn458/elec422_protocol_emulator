# Instructions loaded by `tb_sm_no_smx_instr.sv`

The testbench models a 64-word instruction memory as `imem[0:63]`, with `instr = imem[pc]`. Addresses 0–31 hold the program and 32–39 hold the config words the SM loads at boot: CLKDIV, EXECCTRL, SHIFTCTRL, PINCTRL, low half first (`write_cfg()`). After `rst`, the PC steps through 32–39, then starts the program at 0. Every `reset_all()` fills program address `i` (0–31) with `i_jmp(C_ALWAYS, i)` (`jmp i`). The programs below replace only the listed addresses; every other address retains its self-jump. Entries use the exact instruction-builder expressions from the testbench, so delay and side-set fields remain unambiguous. `NOP` is `16'hA042` (`mov y, y`), and `dss(instruction, field)` inserts the five delay/side-set bits.

Source: [`modules/tb_sm_no_smx_instr.sv`](modules/tb_sm_no_smx_instr.sv).

## `test_instruction_encoders`

This test checks encoder results. It does not write instruction memory.

## `test_set_and_wrap`

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_PINDIRS, 1)` |
| 1 | `i_set(S_PINS, 1)` |
| 2 | `i_set(S_PINS, 0)` |

## `test_delay`

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_PINDIRS, 1)` |
| 1 | `dss(i_set(S_PINS, 1), 1)` |
| 2 | `dss(i_set(S_PINS, 0), 1)` |

## `test_clock_divider_and_enable`

First program:

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_PINDIRS, 1)` |
| 1 | `i_set(S_PINS, 1)` |
| 2 | `i_set(S_PINS, 0)` |

Second program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `i_jmp(C_ALWAYS, 1)` |
| 1 | `i_jmp(C_ALWAYS, 0)` |

## `test_jmp_conditions`

Each call to `check_jmp` writes its three setup instructions to addresses 0–2 and `i_jmp(cond, 10)` to address 3. The cases are:

| Case | Address 0 | Address 1 | Address 2 | Address 3 |
| --- | --- | --- | --- | --- |
| Always | `NOP` | `NOP` | `NOP` | `i_jmp(C_ALWAYS, 10)` |
| `!x`, X = 0 | `i_set(S_X, 0)` | `NOP` | `NOP` | `i_jmp(C_NOT_X, 10)` |
| `!x`, X = 1 | `i_set(S_X, 1)` | `NOP` | `NOP` | `i_jmp(C_NOT_X, 10)` |
| `x--`, X = 1 | `i_set(S_X, 1)` | `NOP` | `NOP` | `i_jmp(C_X_DEC, 10)` |
| `x--`, X = 0 | `i_set(S_X, 0)` | `NOP` | `NOP` | `i_jmp(C_X_DEC, 10)` |
| `!y`, Y = 0 | `i_set(S_Y, 0)` | `NOP` | `NOP` | `i_jmp(C_NOT_Y, 10)` |
| `!y`, Y = 7 | `i_set(S_Y, 7)` | `NOP` | `NOP` | `i_jmp(C_NOT_Y, 10)` |
| `y--`, Y = 2 | `i_set(S_Y, 2)` | `NOP` | `NOP` | `i_jmp(C_Y_DEC, 10)` |
| `y--`, Y = 0 | `i_set(S_Y, 0)` | `NOP` | `NOP` | `i_jmp(C_Y_DEC, 10)` |
| `x!=y`, equal | `i_set(S_X, 3)` | `i_set(S_Y, 3)` | `NOP` | `i_jmp(C_X_NE_Y, 10)` |
| `x!=y`, different | `i_set(S_X, 3)` | `i_set(S_Y, 4)` | `NOP` | `i_jmp(C_X_NE_Y, 10)` |
| Pin high | `NOP` | `NOP` | `NOP` | `i_jmp(C_PIN, 10)` |
| Pin low | `NOP` | `NOP` | `NOP` | `i_jmp(C_PIN, 10)` |
| OSR empty | `NOP` | `NOP` | `NOP` | `i_jmp(C_NOT_OSRE, 10)` |
| OSR after PULL | `i_pull(0, 1)` | `NOP` | `NOP` | `i_jmp(C_NOT_OSRE, 10)` |
| 4 of 8 bits OUT | `i_pull(0, 1)` | `i_out(O_NULL, 4)` | `NOP` | `i_jmp(C_NOT_OSRE, 10)` |
| 8 of 8 bits OUT | `i_pull(0, 1)` | `i_out(O_NULL, 8)` | `NOP` | `i_jmp(C_NOT_OSRE, 10)` |

## `test_jmp_x_dec_loop`

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_X, 3)` |
| 1 | `i_jmp(C_X_DEC, 1)` |
| 2 | `i_jmp(C_ALWAYS, 2)` |

## `test_autopull_autopush_loopback`

| Address | Instruction |
| --- | --- |
| 0 | `i_out(O_X, 16)` |
| 1 | `i_in(IN_X, 16)` |

## `test_shift_and_pin_instructions`

The same program is loaded for both shift directions.

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_PINDIRS, 5'hF)` |
| 1 | `i_pull(0, 1)` |
| 2 | `i_out(O_PINS, 4)` |
| 3 | `i_in(IN_PINS, 4)` |
| 4 | `i_out(O_PINS, 4)` |
| 5 | `i_in(IN_PINS, 4)` |
| 6 | `i_push(0, 1)` |
| 7 | `i_jmp(C_ALWAYS, 7)` |

## `test_pull_blocking`

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_X, 28)` |
| 1 | `i_pull(0, 0)` |
| 2 | `i_mov(MD_Y, MOP_NONE, MS_OSR)` |
| 3 | `i_pull(0, 1)` |
| 4 | `i_jmp(C_ALWAYS, 4)` |

## `test_push_blocking`

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_X, 9)` |
| 1 | `i_in(IN_X, 32)` |
| 2 | `i_push(0, 0)` |
| 3 | `i_in(IN_X, 32)` |
| 4 | `i_push(0, 1)` |
| 5 | `i_jmp(C_ALWAYS, 5)` |

## `test_pull_push_thresholds`

| Address | Instruction |
| --- | --- |
| 0 | `i_pull(0, 1)` |
| 1 | `i_out(O_NULL, 4)` |
| 2 | `i_pull(1, 1)` |
| 3 | `i_out(O_NULL, 4)` |
| 4 | `i_pull(1, 1)` |
| 5 | `i_set(S_X, 3)` |
| 6 | `i_in(IN_X, 4)` |
| 7 | `i_push(1, 1)` |
| 8 | `i_in(IN_X, 4)` |
| 9 | `i_push(1, 1)` |
| 10 | `i_jmp(C_ALWAYS, 10)` |

## `test_pull_with_autopull`

First program:

| Address | Instruction |
| --- | --- |
| 0 | `i_pull(0, 1)` |
| 1 | `i_pull(0, 1)` |
| 2 | `i_out(O_X, 32)` |
| 3 | `NOP` |
| 4 | `i_jmp(C_ALWAYS, 4)` |

Second program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `NOP` |
| 1 | `i_jmp(C_ALWAYS, 1)` |

## `test_mov`

First program:

| Address | Instruction |
| --- | --- |
| 0 | `i_set(S_X, 1)` |
| 1 | `i_mov(MD_Y, MOP_REV, MS_X)` |
| 2 | `i_mov(MD_ISR, MOP_INV, MS_Y)` |
| 3 | `i_mov(MD_OSR, MOP_INV, MS_NULL)` |
| 4 | `i_mov(MD_X, MOP_NONE, MS_ISR)` |
| 5 | `i_mov(MD_PINS, MOP_NONE, MS_X)` |
| 6 | `i_mov(MD_Y, MOP_NONE, MS_PINS)` |
| 7 | `i_mov(MD_X, MOP_NONE, MS_STATUS)` |
| 8 | `i_jmp(C_ALWAYS, 8)` |

Second program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `i_mov(MD_X, MOP_NONE, MS_STATUS)` |
| 1 | `i_jmp(C_ALWAYS, 1)` |

Third program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `i_mov(MD_Y, MOP_NONE, MS_STATUS)` |
| 1 | `i_jmp(C_ALWAYS, 1)` |

## `test_sideset`

SPI transmit program:

| Address | Instruction |
| --- | --- |
| 0 | `dss(i_out(O_PINS, 1), 5'b00000)` |
| 1 | `dss(i_jmp(C_ALWAYS, 0), 5'b10000)` |

Optional side-set program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `dss(i_set(S_X, 0), 5'b11010)` |
| 1 | `dss(i_set(S_X, 1), 5'b00001)` |
| 2 | `dss(i_set(S_X, 2), 5'b10000)` |
| 3 | `i_jmp(C_ALWAYS, 3)` |

Side-set versus SET program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `dss(i_set(S_PINS, 1), 5'b00000)` |
| 1 | `dss(i_set(S_PINS, 0), 5'b10000)` |
| 2 | `i_jmp(C_ALWAYS, 2)` |

Side-set pin direction program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `dss(i_set(S_PINS, 1), 5'b10000)` |
| 1 | `i_jmp(C_ALWAYS, 1)` |

## `test_wait`

GPIO wait program:

| Address | Instruction |
| --- | --- |
| 0 | `dss(i_wait(1, W_GPIO, 14), 2)` |
| 1 | `i_set(S_PINS, 1)` |
| 2 | `i_jmp(C_ALWAYS, 2)` |

Pin wait program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `i_wait(0, W_PIN, 3)` |
| 1 | `i_jmp(C_ALWAYS, 1)` |

IRQ wait program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `i_wait(1, W_IRQ, 5)` |
| 1 | `i_wait(0, W_IRQ, 2)` |
| 2 | `i_wait(1, W_IRQ, 5'h13)` |
| 3 | `i_jmp(C_ALWAYS, 3)` |

## `test_irq`

| Address | Instruction |
| --- | --- |
| 0 | `i_irq(0, 0, 3)` |
| 1 | `i_irq(0, 0, 5'h16)` |
| 2 | `i_irq(1, 0, 3)` |
| 3 | `i_irq(0, 1, 4)` |
| 4 | `i_set(S_X, 30)` |
| 5 | `i_jmp(C_ALWAYS, 5)` |

## `test_out_pc_and_mov_pc`

| Address | Instruction |
| --- | --- |
| 0 | `i_pull(0, 1)` |
| 1 | `i_out(O_PC, 5)` |
| 12 | `i_set(S_Y, 14)` |
| 13 | `i_mov(MD_PC, MOP_NONE, MS_Y)` |
| 14 | `i_set(S_X, 1)` |
| 15 | `i_jmp(C_ALWAYS, 15)` |

## `test_sm_restart`

First program:

| Address | Instruction |
| --- | --- |
| 0 | `i_pull(0, 1)` |
| 1 | `i_set(S_X, 5)` |
| 2 | `i_in(IN_X, 8)` |
| 3 | `dss(i_set(S_Y, 6), 7)` |
| 4 | `i_jmp(C_ALWAYS, 4)` |

Second program, after another reset:

| Address | Instruction |
| --- | --- |
| 0 | `i_irq(0, 1, 2)` |

## `test_data_width_limits`

| Address | Instruction |
| --- | --- |
| 0 | `i_pull(0, 1)` |
| 1 | `i_out(O_X, 20)` |
| 2 | `i_set(S_PINS, 1)` |
| 3 | `i_in(IN_X, 24)` |
| 4 | `i_jmp(C_ALWAYS, 4)` |

## `test_uart_tx`

The same program is loaded for both clock divisors.

| Address | Instruction | Meaning |
| --- | --- | --- |
| 0 | `16'h9FA0` | `pull side 1 [7]` |
| 1 | `16'hF727` | `set x, 7 side 0 [7]` |
| 2 | `16'h6001` | `out pins, 1` |
| 3 | `16'h0642` | `jmp x--, 2 [6]` |
