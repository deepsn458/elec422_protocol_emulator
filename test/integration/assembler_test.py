#!/usr/bin/env python3
"""Check that the PIO assembler reproduces the state machine testbench programs.

    python3 test/integration/assembler_test.py

For every program loaded by test_set_and_wrap through test_pins_re in
tb_sm_no_smx_instr.sv, plus the full-duplex program in tb_sm_uart.sv, this script:

1. writes a golden hex image based on the corresponding testbench
   (assembler_test_outputs/golden/<name>.hex),
2. assembles the matching hand-written source pio_programs/<name>.pio with
   src/assembler/pio_assembler.py (assembler_test_outputs/generated/<name>.hex),
3. compares the two images line by line, and
4. writes assembler_test_outputs/assembler_test.log with one PASS, FAIL,
   XFAIL or XPASS line per program, followed by the mismatched lines.

An image is 32 instruction slots (unused slots are NOP, as in reset_all())
followed by CLKDIV, EXECCTRL, SHIFTCTRL and PINCTRL, low halfword first, as in
write_cfg(). The golden images can be loaded into a testbench with $readmemh.

The exit status is 1 if any program FAILs or XPASSes, otherwise 0.
programs.txt lists the cases in run order.
"""

import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ASSEMBLER = REPO / "src" / "assembler" / "pio_assembler.py"
SOURCES = HERE / "pio_programs"
MANIFEST = HERE / "programs.txt"
OUTPUTS = HERE / "assembler_test_outputs"
GOLDEN = OUTPUTS / "golden"
GENERATED = OUTPUTS / "generated"
LOG = OUTPUTS / "assembler_test.log"

SLOTS = 32
CONFIG_NAMES = ("CLKDIV", "EXECCTRL", "SHIFTCTRL", "PINCTRL")

# ----------------------------------------------------------------------------
# Instruction and config encoders, copied from tb_sm_no_smx_instr.sv
# ----------------------------------------------------------------------------

C_ALWAYS, C_NOT_X, C_X_DEC, C_NOT_Y, C_Y_DEC, C_X_NE_Y, C_PIN, C_NOT_OSRE = range(8)
W_GPIO, W_PIN, W_IRQ = range(3)
IN_PINS, IN_X, IN_Y, IN_NULL, IN_ISR, IN_OSR = 0, 1, 2, 3, 6, 7
O_PINS, O_X, O_Y, O_NULL, O_PINDIRS, O_PC, O_ISR, O_EXEC = range(8)
MD_PINS, MD_X, MD_Y, MD_EXEC, MD_PC, MD_ISR, MD_OSR = 0, 1, 2, 4, 5, 6, 7
MOP_NONE, MOP_INV, MOP_REV = range(3)
MS_PINS, MS_X, MS_Y, MS_NULL, MS_STATUS, MS_ISR, MS_OSR = 0, 1, 2, 3, 5, 6, 7
S_PINS, S_X, S_Y, S_PINDIRS = 0, 1, 2, 4

NOP = 0xA042  # mov y, y


def i_jmp(cond, addr):
    return (0b000 << 13) | (cond << 5) | addr


def i_wait(pol, src, idx):
    return (0b001 << 13) | (pol << 7) | (src << 5) | idx


def i_in(src, n):
    return (0b010 << 13) | (src << 5) | (n & 0x1F)


def i_out(dst, n):
    return (0b011 << 13) | (dst << 5) | (n & 0x1F)


def i_push(iffull, blk):
    return (0b100 << 13) | (iffull << 6) | (blk << 5)


def i_pull(ifempty, blk):
    return (0b100 << 13) | (1 << 7) | (ifempty << 6) | (blk << 5)


def i_mov(dst, op, src):
    return (0b101 << 13) | (dst << 5) | (op << 3) | src


def i_irq(clr, wt, idx):
    return (0b110 << 13) | (clr << 6) | (wt << 5) | idx


def i_set(dst, data):
    return (0b111 << 13) | (dst << 5) | data


def dss(ins, fld):
    """Fill in the delay/side-set field, bits [12:8]."""
    return ins | (fld << 8)


def pinctrl_f(sideset_count, set_count, out_count, in_base, sideset_base, set_base, out_base):
    return ((sideset_count << 29) | (set_count << 26) | (out_count << 20) | (in_base << 15)
            | (sideset_base << 10) | (set_base << 5) | out_base)


def execctrl_f(side_en, side_pindir, jmp_pin, wrap_top, wrap_bottom, status_sel, status_n):
    return ((side_en << 30) | (side_pindir << 29) | (jmp_pin << 24) | (wrap_top << 12)
            | (wrap_bottom << 7) | (status_sel << 4) | status_n)


def shiftctrl_f(pull_thresh, push_thresh, out_right, in_right, autopull, autopush):
    return ((pull_thresh << 25) | (push_thresh << 20) | (out_right << 19) | (in_right << 18)
            | (autopull << 17) | (autopush << 16))


# reset_all() values.
CLKDIV = 0x0001_0000
EXECCTRL = 0x0001_F000
SHIFTCTRL = 0x000C_0000
PINCTRL = 0x1400_0000

# ----------------------------------------------------------------------------
# Programs, in testbench order
# ----------------------------------------------------------------------------


@dataclass
class GoldenProgram:
    imem: dict                  # address -> word; other slots are NOP
    clkdiv: int = CLKDIV
    execctrl: int = EXECCTRL
    shiftctrl: int = SHIFTCTRL
    pinctrl: int = PINCTRL
    config: tuple = field(init=False)

    def __post_init__(self):
        self.config = (self.clkdiv, self.execctrl, self.shiftctrl, self.pinctrl)


def words(*ws):
    """Instructions at consecutive addresses from 0."""
    return dict(enumerate(ws))


def golden_programs():
    images = {}

    def add(name, imem, **config):
        images[name] = GoldenProgram(imem, **config)

    # test_set_and_wrap: squarewave_fast, wrap 2 -> 1, SET on GPIO 3.
    square = words(i_set(S_PINDIRS, 1), i_set(S_PINS, 1), i_set(S_PINS, 0))
    square_exec = execctrl_f(0, 0, 0, 2, 1, 0, 0)
    square_pins = pinctrl_f(0, 1, 0, 0, 0, 3, 0)
    add("test_set_and_wrap", square,
        execctrl=square_exec, pinctrl=square_pins)

    # test_delay: squarewave with one delay cycle per level.
    add("test_delay",
        words(i_set(S_PINDIRS, 1), dss(i_set(S_PINS, 1), 1),
              dss(i_set(S_PINS, 0), 1)),
        execctrl=square_exec, pinctrl=square_pins)

    # test_clock_divider_and_enable
    add("test_clock_divider_and_enable_0", square,
        clkdiv=(3 << 16), execctrl=square_exec, pinctrl=square_pins)
    add("test_clock_divider_and_enable_1",
        words(i_jmp(C_ALWAYS, 1), i_jmp(C_ALWAYS, 0)),
        clkdiv=(2 << 16) | (0x80 << 8))

    # test_jmp_conditions: check_jmp(cond, taken, s0, s1, s2, what).
    pin9 = execctrl_f(0, 0, 9, 31, 0, 0, 0)
    osre8 = shiftctrl_f(8, 0, 1, 1, 0, 0)
    jmp_cases = [
        (C_ALWAYS, NOP, NOP, NOP, dict(execctrl=pin9)),
        (C_NOT_X, i_set(S_X, 0), NOP, NOP, {}),
        (C_NOT_X, i_set(S_X, 1), NOP, NOP, {}),
        (C_X_DEC, i_set(S_X, 1), NOP, NOP, {}),
        (C_X_DEC, i_set(S_X, 0), NOP, NOP, {}),
        (C_NOT_Y, i_set(S_Y, 0), NOP, NOP, {}),
        (C_NOT_Y, i_set(S_Y, 7), NOP, NOP, {}),
        (C_Y_DEC, i_set(S_Y, 2), NOP, NOP, {}),
        (C_Y_DEC, i_set(S_Y, 0), NOP, NOP, {}),
        (C_X_NE_Y, i_set(S_X, 3), i_set(S_Y, 3), NOP, {}),
        (C_X_NE_Y, i_set(S_X, 3), i_set(S_Y, 4), NOP, {}),
        (C_PIN, NOP, NOP, NOP, dict(execctrl=pin9)),
        (C_PIN, NOP, NOP, NOP, dict(execctrl=pin9)),
        (C_NOT_OSRE, NOP, NOP, NOP, {}),
        (C_NOT_OSRE, i_pull(0, 1), NOP, NOP, {}),
        (C_NOT_OSRE, i_pull(0, 1), i_out(O_NULL, 4), NOP,
         dict(shiftctrl=osre8)),
        (C_NOT_OSRE, i_pull(0, 1), i_out(O_NULL, 8), NOP,
         dict(shiftctrl=osre8)),
    ]
    for n, (cond, s0, s1, s2, cfg) in enumerate(jmp_cases):
        imem = {0: s0, 1: s1, 2: s2, 3: i_jmp(cond, 10),
                4: i_jmp(C_ALWAYS, 4), 10: i_jmp(C_ALWAYS, 10)}
        add(f"test_jmp_conditions_{n}", imem, **cfg)

    # test_jmp_x_dec_loop
    add("test_jmp_x_dec_loop",
        words(i_set(S_X, 3), i_jmp(C_X_DEC, 1), i_jmp(C_ALWAYS, 2)))

    # test_autopull_autopush_loopback
    add("test_autopull_autopush_loopback",
        words(i_out(O_X, 16), i_in(IN_X, 16)),
        execctrl=execctrl_f(0, 0, 0, 1, 0, 0, 0),
        shiftctrl=shiftctrl_f(0, 0, 1, 1, 1, 1))

    # test_shift_and_pin_instructions: dir 0 = OUT right, IN left; dir 1 = reverse.
    shift_prog = words(i_set(S_PINDIRS, 0xF), i_pull(0, 1), i_out(O_PINS, 4),
            i_in(IN_PINS, 4), i_out(O_PINS, 4), i_in(IN_PINS, 4),
            i_push(0, 1), i_jmp(C_ALWAYS, 7))
    shift_pins = pinctrl_f(0, 4, 4, 8, 0, 8, 8)
    add("test_shift_and_pin_instructions_0", shift_prog,
        shiftctrl=shiftctrl_f(0, 0, 1, 0, 0, 0), pinctrl=shift_pins)
    add("test_shift_and_pin_instructions_1", shift_prog,
        shiftctrl=shiftctrl_f(0, 0, 0, 1, 0, 0), pinctrl=shift_pins)

    # test_pull_blocking
    add("test_pull_blocking",
        words(i_set(S_X, 28), i_pull(0, 0), i_mov(MD_Y, MOP_NONE, MS_OSR),
              i_pull(0, 1), i_jmp(C_ALWAYS, 4)))

    # test_push_blocking
    add("test_push_blocking",
        words(i_set(S_X, 9), i_in(IN_X, 32), i_push(0, 0), i_in(IN_X, 32),
              i_push(0, 1), i_jmp(C_ALWAYS, 5)))

    # test_pull_push_thresholds
    add("test_pull_push_thresholds",
        words(i_pull(0, 1), i_out(O_NULL, 4), i_pull(1, 1), i_out(O_NULL, 4),
              i_pull(1, 1), i_set(S_X, 3), i_in(IN_X, 4), i_push(1, 1),
              i_in(IN_X, 4), i_push(1, 1), i_jmp(C_ALWAYS, 10)),
        shiftctrl=shiftctrl_f(8, 8, 1, 0, 0, 0))

    # test_pull_with_autopull
    autopull = shiftctrl_f(0, 0, 1, 1, 1, 0)
    add("test_pull_with_autopull_0",
        words(i_pull(0, 1), i_pull(0, 1), i_out(O_X, 32), NOP,
              i_jmp(C_ALWAYS, 4)),
        shiftctrl=autopull)
    add("test_pull_with_autopull_1",
        words(NOP, i_jmp(C_ALWAYS, 1)), shiftctrl=autopull)

    # test_mov
    add("test_mov_0",
        words(i_set(S_X, 1), i_mov(MD_Y, MOP_REV, MS_X),
              i_mov(MD_ISR, MOP_INV, MS_Y), i_mov(MD_OSR, MOP_INV, MS_NULL),
              i_mov(MD_X, MOP_NONE, MS_ISR), i_mov(MD_PINS, MOP_NONE, MS_X),
              i_mov(MD_Y, MOP_NONE, MS_PINS), i_mov(MD_X, MOP_NONE, MS_STATUS),
              i_jmp(C_ALWAYS, 8)),
        execctrl=execctrl_f(0, 0, 0, 31, 0, 0, 2),
        pinctrl=pinctrl_f(0, 0, 8, 12, 0, 0, 8))
    add("test_mov_1",
        words(i_mov(MD_X, MOP_NONE, MS_STATUS), i_jmp(C_ALWAYS, 1)),
        execctrl=execctrl_f(0, 0, 0, 31, 0, 0, 2))
    add("test_mov_2",
        words(i_mov(MD_Y, MOP_NONE, MS_STATUS), i_jmp(C_ALWAYS, 1)),
        execctrl=execctrl_f(0, 0, 0, 31, 0, 1, 1))

    # test_sideset
    add("test_sideset_0",
        words(dss(i_out(O_PINS, 1), 0b00000), dss(i_jmp(C_ALWAYS, 0), 0b10000)),
        shiftctrl=shiftctrl_f(8, 0, 1, 1, 1, 0),
        pinctrl=pinctrl_f(1, 0, 1, 0, 2, 0, 3))
    add("test_sideset_1",
        words(dss(i_set(S_X, 0), 0b11010), dss(i_set(S_X, 1), 0b00001),
              dss(i_set(S_X, 2), 0b10000), i_jmp(C_ALWAYS, 3)),
        execctrl=execctrl_f(1, 0, 0, 31, 0, 0, 0),
        pinctrl=pinctrl_f(2, 0, 0, 0, 5, 0, 0))
    add("test_sideset_2",
        words(dss(i_set(S_PINS, 1), 0b00000), dss(i_set(S_PINS, 0), 0b10000),
              i_jmp(C_ALWAYS, 2)),
        pinctrl=pinctrl_f(1, 1, 0, 0, 6, 6, 0))
    add("test_sideset_3",
        words(dss(i_set(S_PINS, 1), 0b10000), i_jmp(C_ALWAYS, 1)),
        execctrl=execctrl_f(0, 1, 0, 31, 0, 0, 0),
        pinctrl=pinctrl_f(1, 1, 0, 0, 6, 6, 0))

    # test_wait
    add("test_wait_0",
        words(dss(i_wait(1, W_GPIO, 14), 2), i_set(S_PINS, 1), i_jmp(C_ALWAYS, 2)),
        pinctrl=pinctrl_f(0, 1, 0, 0, 0, 0, 0))
    add("test_wait_1",
        words(i_wait(0, W_PIN, 3), i_jmp(C_ALWAYS, 1)),
        pinctrl=pinctrl_f(0, 0, 0, 10, 0, 0, 0))
    add("test_wait_2",
        words(i_wait(1, W_IRQ, 5), i_wait(0, W_IRQ, 2), i_wait(1, W_IRQ, 0x13),
              i_jmp(C_ALWAYS, 3)))

    # test_irq
    add("test_irq",
        words(i_irq(0, 0, 3), i_irq(0, 0, 0x16), i_irq(1, 0, 3), i_irq(0, 1, 4),
              i_set(S_X, 30), i_jmp(C_ALWAYS, 5)))

    # test_out_pc_and_mov_pc
    add("test_out_pc_and_mov_pc",
        {0: i_pull(0, 1), 1: i_out(O_PC, 5), 12: i_set(S_Y, 14),
         13: i_mov(MD_PC, MOP_NONE, MS_Y), 14: i_set(S_X, 1),
         15: i_jmp(C_ALWAYS, 15)})

    # test_sm_restart
    add("test_sm_restart_0",
        words(i_pull(0, 1), i_set(S_X, 5), i_in(IN_X, 8), dss(i_set(S_Y, 6), 7),
              i_jmp(C_ALWAYS, 4)),
        shiftctrl=shiftctrl_f(0, 0, 1, 0, 0, 0))
    add("test_sm_restart_1",
        words(i_irq(0, 1, 2)))

    # test_data_width_limits
    add("test_data_width_limits",
        words(i_pull(0, 1), i_out(O_X, 20), i_set(S_PINS, 1), i_in(IN_X, 24),
              i_jmp(C_ALWAYS, 4)),
        shiftctrl=shiftctrl_f(0, 0, 1, 1, 0, 0),
        pinctrl=pinctrl_f(0, 1, 0, 0, 0, 20, 0))

    # test_uart_tx: the datasheet uart_tx program at divisors 1 and 3.
    uart = words(0x9FA0, 0xF727, 0x6001, 0x0642)
    for n, div in enumerate((1, 3)):
        add(f"test_uart_tx_{n}", uart,
            clkdiv=div << 16,
            execctrl=execctrl_f(1, 0, 0, 3, 0, 0, 0),
            pinctrl=pinctrl_f(2, 0, 1, 0, 4, 0, 4))

    # test_gpio_fault: FAULT_VEC is EXECCTRL[23:19].
    fv = 20
    fault_exec = execctrl_f(0, 0, 0, 31, 0, 0, 0) | (fv << 19)
    add("test_gpio_fault_0",
        {0: i_set(S_PINDIRS, 1), 1: dss(i_set(S_PINS, 1), 3), 2: i_jmp(C_ALWAYS, 1),
         fv: i_set(S_PINS, 0), fv + 1: i_jmp(C_ALWAYS, fv + 1)},
        execctrl=fault_exec, pinctrl=pinctrl_f(0, 1, 0, 0, 0, 3, 0))
    add("test_gpio_fault_1",
        {0: dss(i_set(S_X, 1), 5), 1: i_jmp(C_ALWAYS, 0), fv: i_jmp(C_ALWAYS, fv)},
        execctrl=fault_exec)
    add("test_gpio_fault_2",
        {0: i_irq(0, 1, 0), fv: i_jmp(C_ALWAYS, fv)},
        execctrl=fault_exec)
    add("test_gpio_fault_3",
        {7: i_jmp(C_ALWAYS, 7)},
        execctrl=execctrl_f(0, 0, 0, 31, 0, 0, 0) | (7 << 19))

    # test_pins_re
    add("test_pins_re_0",
        words(i_in(IN_PINS, 3), i_wait(1, W_GPIO, 9), i_wait(1, W_PIN, 2),
              i_jmp(C_PIN, 4), i_mov(MD_X, MOP_NONE, MS_PINS), i_set(S_PINS, 1),
              i_jmp(C_ALWAYS, 6)),
        execctrl=execctrl_f(0, 0, 9, 31, 0, 0, 0),
        pinctrl=pinctrl_f(0, 1, 0, 4, 0, 3, 0))
    add("test_pins_re_1",
        words(i_wait(1, W_GPIO, 12)))
    # tb_sm_uart.sv: prog_hex() and reset_all(24'h0100), with TX GPIO 6 and RX GPIO 2.
    full_duplex_uart = words(
        0xE001, 0xE081, 0xA02B, 0x8040, 0x80C0, 0x6001, 0x01C4, 0x80C0,
        0x6001, 0xE147, 0x80C0, 0x6201, 0x80C0, 0x6201, 0x80C0, 0x6001,
        0x4001, 0x008A, 0x80C0, 0x6201, 0x80C0, 0x6201, 0x80C0, 0x6001,
        0x00C3, 0xC014, 0x80C0, 0x6001, 0x01C4, 0x001D, 0x001E, 0x001F,
    )
    add("tb_sm_uart", full_duplex_uart,
        execctrl=execctrl_f(0, 0, 2, 28, 26, 0, 0),
        shiftctrl=shiftctrl_f(8, 8, 1, 1, 0, 0),
        pinctrl=pinctrl_f(0, 1, 1, 2, 0, 6, 6))
    return images


# ----------------------------------------------------------------------------
# Images, disassembly and comparison
# ----------------------------------------------------------------------------


def golden_image(program):
    image = [NOP] * SLOTS
    for address, word in program.imem.items():
        image[address] = word
    for value in program.config:
        image += [value & 0xFFFF, value >> 16]  # low half first, as write_cfg()
    return image


def read_image(path):
    return [int(line, 16) for line in path.read_text(encoding="ascii").split()]


def write_image(path, image):
    path.write_text("".join(f"{word:04X}\n" for word in image), encoding="ascii")


JMP_CONDS = ("", "!x, ", "x--, ", "!y, ", "y--, ", "x!=y, ", "pin, ", "!osre, ")
WAIT_SRCS = ("gpio", "pin", "irq", "reserved")
IN_SRCS = ("pins", "x", "y", "null", "reserved4", "reserved5", "isr", "osr")
OUT_DSTS = ("pins", "x", "y", "null", "pindirs", "pc", "isr", "exec")
MOV_DSTS = ("pins", "x", "y", "reserved3", "exec", "pc", "isr", "osr")
MOV_OPS = ("", "!", "::", "reserved3 ")
MOV_SRCS = ("pins", "x", "y", "null", "reserved4", "status", "isr", "osr")
SET_DSTS = ("pins", "x", "y", "reserved3", "pindirs", "reserved5", "reserved6", "reserved7")


def irq_name(index):
    return f"{index & 7}" + (" rel" if index & 0x10 else "")


def disassemble(word):
    """Readable form of an instruction. Bits [12:8] are shown raw as ds=."""
    if word == NOP:
        return "nop"
    op, a, b = word >> 13, (word >> 5) & 7, word & 0x1F
    if op == 0:
        text = f"jmp {JMP_CONDS[a]}{b}"
    elif op == 1:
        src = (word >> 5) & 3
        index = irq_name(b) if src == W_IRQ else str(b)
        text = f"wait {(word >> 7) & 1} {WAIT_SRCS[src]} {index}"
    elif op == 2:
        text = f"in {IN_SRCS[a]}, {b or 32}"
    elif op == 3:
        text = f"out {OUT_DSTS[a]}, {b or 32}"
    elif op == 4:
        pull = (word >> 7) & 1
        cond = ("ifempty " if pull else "iffull ") if (word >> 6) & 1 else ""
        text = f"{'pull' if pull else 'push'} {cond}{'block' if (word >> 5) & 1 else 'noblock'}"
    elif op == 5:
        text = f"mov {MOV_DSTS[a]}, {MOV_OPS[(word >> 3) & 3]}{MOV_SRCS[word & 7]}"
    elif op == 6:
        mode = "clear" if (word >> 6) & 1 else "wait" if (word >> 5) & 1 else "set"
        text = f"irq {mode} {irq_name(b)}"
    else:
        text = f"set {SET_DSTS[a]}, {b}"
    delay_sideset = (word >> 8) & 0x1F
    return text + (f" ds={delay_sideset:05b}" if delay_sideset else "")


def describe_line(index):
    """Hex row (1-based, as the assembler reports) and what the row holds."""
    if index < SLOTS:
        return f"line {index + 1:2d} (slot {index})"
    if index < SLOTS + 2 * len(CONFIG_NAMES):
        register = CONFIG_NAMES[(index - SLOTS) // 2]
        half = "low" if (index - SLOTS) % 2 == 0 else "high"
        return f"line {index + 1:2d} ({register} {half} half)"
    return f"line {index + 1:2d} (beyond the image)"


def describe_word(index, word):
    if word is None:
        return "----"
    if index < SLOTS:
        return f"{word:04X} ({disassemble(word)})"
    return f"{word:04X}"


def compare(golden, generated):
    """Mismatch descriptions; empty if the images are identical."""
    mismatches = []
    if len(golden) != len(generated):
        mismatches.append(f"length: expected {len(golden)} lines, got {len(generated)}")
    for index in range(max(len(golden), len(generated))):
        want = golden[index] if index < len(golden) else None
        got = generated[index] if index < len(generated) else None
        if want != got:
            mismatches.append(f"{describe_line(index)}: expected {describe_word(index, want)}, "
                              f"got {describe_word(index, got)}")
    return mismatches


def assemble(source, output):
    """Run the assembler CLI. Returns an error message, or "" on success."""
    if not source.exists():
        return f"missing source {source.relative_to(REPO)}"
    # Repo-relative paths keep the assembler's error messages short.
    result = subprocess.run([sys.executable, str(ASSEMBLER.relative_to(REPO)),
                             str(source.relative_to(REPO)), "-o", str(output.relative_to(REPO))],
                            capture_output=True, text=True, cwd=REPO)
    if result.returncode != 0:
        return "assembler error: " + (result.stderr.strip() or f"exit {result.returncode}")
    return ""


def read_programs(images):
    programs = {}
    for number, line in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, separator, metadata = line.partition("|")
        description, _, xfail = metadata.partition("|")
        name, description, xfail = name.strip(), description.strip(), xfail.strip()
        if not separator or not description or name not in images:
            raise ValueError(f"{MANIFEST.name}:{number}: expected a known program name and description")
        if name in programs:
            raise ValueError(f"{MANIFEST.name}:{number}: duplicate program {name!r}")
        programs[name] = (description, xfail)
    if not programs:
        raise ValueError(f"{MANIFEST.name}: no programs listed")
    return programs


def main():
    images = golden_programs()
    try:
        programs = read_programs(images)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    GOLDEN.mkdir(parents=True, exist_ok=True)
    GENERATED.mkdir(parents=True, exist_ok=True)

    log = []
    counts = {"PASS": 0, "FAIL": 0, "XFAIL": 0, "XPASS": 0}
    width = max(map(len, programs))

    for name, (description, xfail) in programs.items():
        golden = golden_image(images[name])
        write_image(GOLDEN / f"{name}.hex", golden)

        output = GENERATED / f"{name}.hex"
        output.unlink(missing_ok=True)
        error = assemble(SOURCES / f"{name}.pio", output)
        details = [error] if error else compare(golden, read_image(output))

        if xfail:
            status = "XFAIL" if details else "XPASS"
        else:
            status = "FAIL" if details else "PASS"
        counts[status] += 1

        line = f"{name:<{width}}  {status:<5}  {description}"
        if xfail:
            line += f"  [expected to fail: {xfail}]"
        log.append(line)
        log.extend(f"    {detail}" for detail in details)

    summary = ", ".join(f"{count} {status}" for status, count in counts.items())
    log.append("")
    log.append(f"{len(programs)} programs: {summary}")
    LOG.write_text("\n".join(log) + "\n", encoding="utf-8")

    print("\n".join(log))
    print(f"\nlog: {LOG.relative_to(REPO)}")
    return 1 if counts["FAIL"] or counts["XPASS"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
