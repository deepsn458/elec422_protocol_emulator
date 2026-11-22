#!/usr/bin/env python3
"""Assemble one PIO program into a hex image for the project's boot FSM.

    python3 pio_assembler.py program.pio -o program.hex --show-config
    python3 pio_assembler.py program.pio --halfword-order high-first

The image has --max-lines instruction slots followed by eight config words:
two halfwords each for CLKDIV, EXECCTRL, SHIFTCTRL, and PINCTRL, in that order.
The boot FSM reads the config words from address max_lines, then starts at 0.
By default, execution wraps from the last instruction slot back to address 0.

Use .set_clkdiv, .set_execctrl, .set_shiftctrl, or .set_pinctrl followed by
eight hex digits (optionally prefixed with 0x) to override a register default.
Wrap and side-set fields are regenerated from the source.
"""

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path

MAX_INSTRUCTION_WORDS = 32
NOP = 0xA042

# Boot register order is also the configuration order in the hex file.
# EXECCTRL wrap and side-set fields, and PINCTRL side-set count, are packed below.
REGISTER_DEFAULTS = {
    "CLKDIV": 0x00010000,
    "EXECCTRL": 0x0001F000,
    "SHIFTCTRL": 0x000C0000,
    "PINCTRL": 0x14000000,
}
REGISTER_DIRECTIVES = {f".set_{name.lower()}": name for name in REGISTER_DEFAULTS}
CONFIG_VALUE = re.compile(r"(?:0[xX])?[0-9A-Fa-f]{8}")

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
LABEL = re.compile(r"([A-Za-z_][A-Za-z_0-9]*)\s*:(?!:)")
NUMBER = re.compile(r"0[xX][0-9A-Fa-f]+|0[bB][01]+|[0-9]+")
TOKEN = re.compile(r"\s+|[A-Za-z_0-9]+|\.[A-Za-z_]+|!=|::|[][!,~\-]|(?P<invalid>.)")


class Operands:
    def __init__(self, source, line, labels):
        self.line = line
        self.labels = labels
        self.tokens = []
        for match in TOKEN.finditer(source):
            token = match.group()
            if match["invalid"]:
                raise self.fail(f"unexpected character {token!r}")
            if not token.isspace():
                self.tokens.append(token)
        self.position = 0

    def fail(self, message):
        return ValueError(f"line {self.line}: {message}")

    def peek(self):
        return self.tokens[self.position] if self.position < len(self.tokens) else ""

    def take(self, description):
        token = self.peek()
        if not token:
            raise self.fail(f"expected {description}")
        self.position += 1
        return token

    def accept(self, *keywords):
        end = self.position + len(keywords)
        if tuple(token.lower() for token in self.tokens[self.position:end]) != keywords:
            return False
        self.position = end
        return True

    def expect(self, keyword):
        if not self.accept(keyword):
            raise self.fail(f"expected {keyword!r}")

    def finish(self):
        if self.peek():
            raise self.fail(f"unexpected token {self.peek()!r}")

    def choice(self, choices, description):
        token = self.take(description).lower()
        if token not in choices:
            raise self.fail(f"invalid {description} {token!r}; use {', '.join(choices)}")
        return choices[token]

    def bounded(self, description, low, high, *, label=False):
        negative = self.accept("-")
        token = self.take(description)
        if label and not negative and token in self.labels:
            value = self.labels[token]
        elif NUMBER.fullmatch(token):
            base = 0 if token.lower().startswith(("0x", "0b")) else 10
            try:
                value = int(token, base)
            except ValueError as error:
                raise self.fail(f"invalid {description} {token!r}") from error
            if negative:
                value = -value
        else:
            raise self.fail(f"invalid {description} {token!r}")
        if not low <= value <= high:
            raise self.fail(f"{description} must be {low}..{high}, got {value}")
        return value


@dataclass(frozen=True)
class SideSet:
    data_bits: int = 0
    optional: bool = False
    pindirs: bool = False

    @property
    def total_bits(self) -> int:
        return self.data_bits + int(self.optional)

    def encode(self, operands: Operands) -> int:
        # Instruction bits [12:8] are shared by every opcode. The MSBs hold
        # optional enable (if configured), then side data; the LSBs hold delay.
        # Side-set applies when the instruction starts; delay starts when it completes.
        delay_bits = 5 - self.total_bits
        field = 0
        if operands.accept("side"):
            if not self.data_bits:
                raise operands.fail("'side' requires a .side_set directive")
            side = operands.bounded("side-set value", 0, (1 << self.data_bits) - 1)
            field = side << delay_bits
            if self.optional:
                field |= 1 << 4  # Field bit 4 is instruction bit 12.
        elif self.data_bits and not self.optional:
            raise operands.fail("instruction requires 'side <value>'")
        if operands.accept("["):
            field |= operands.bounded("delay", 0, (1 << delay_bits) - 1)
            operands.expect("]")
        return field << 8


# JMP condition codes for bits [7:5]. X-- and Y-- always decrement; the
# branch tests the old value. These names select the RP2040 X and Y registers.
JMP_CONDITIONS = {
    ("!", "x"): 0b001,        # X == 0.
    ("x", "-", "-"): 0b010,   # X != 0 before decrement.
    ("!", "y"): 0b011,        # Y == 0.
    ("y", "-", "-"): 0b100,   # Y != 0 before decrement.
    ("x", "!=", "y"): 0b101,  # X != Y.
    ("pin",): 0b110,          # Configured JMP pin is high.
    ("!", "osre"): 0b111,     # OSR is not empty per its shift threshold.
}

WAIT_SOURCES = {"gpio": 0b00, "pin": 0b01, "irq": 0b10}
IN_SOURCES = {
    "pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011,
    "isr": 0b110, "osr": 0b111,
}
OUT_DESTINATIONS = {
    "pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011,
    "pindirs": 0b100, "pc": 0b101, "isr": 0b110, "exec": 0b111,
}
MOV_DESTINATIONS = {
    "pins": 0b000, "x": 0b001, "y": 0b010, "exec": 0b100,
    "pc": 0b101, "isr": 0b110, "osr": 0b111,
}
MOV_OPERATIONS = {"!": 0b01, "~": 0b01, "::": 0b10}
MOV_SOURCES = {
    "pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011,
    "status": 0b101, "isr": 0b110, "osr": 0b111,
}
IRQ_MODES = ("set", "nowait", "wait", "clear")
SET_DESTINATIONS = {"pins": 0b000, "x": 0b001, "y": 0b010, "pindirs": 0b100}


def irq_index(operands: Operands) -> int:
    # Bit [4] requests SM-relative IRQ indexing, [3] is reserved and zero,
    # and [2:0] select IRQ 0..7. REL adds the SM ID to [1:0] modulo 4.
    index = operands.bounded("IRQ index", 0, 7)
    return index | (int(operands.accept("rel")) << 4)


def encode_instruction(mnemonic: str, operands: Operands, max_lines: int) -> int:
    """Encode the opcode and instruction-specific fields (datasheet §3.4)."""
    if mnemonic == "jmp":
        # [15:13] = 000, [12:8] = delay/side-set, [7:5] = condition,
        # [4:0] = absolute instruction memory address.
        condition = 0b000  # No condition means always jump.
        for keywords, code in JMP_CONDITIONS.items():
            if operands.accept(*keywords):
                condition = code
                operands.accept(",")
                break
        address = operands.bounded(
            "JMP target address (config memory is protected)", 0, max_lines - 1,
            label=True,
        )
        return (0b000 << 13) | (condition << 5) | address

    if mnemonic == "wait":
        # [15:13] = 001, [12:8] = delay/side-set, [7] = polarity (0/1),
        # [6:5] = source (00 absolute GPIO, 01 mapped pin, 10 IRQ, 11 reserved),
        # [4:0] = pin index or IRQ index with optional REL in bit [4].
        # Stall until the source matches polarity. WAIT 1 IRQ then clears the flag.
        polarity = operands.bounded("WAIT polarity", 0, 1)
        operands.accept(",")
        source = operands.choice(WAIT_SOURCES, "WAIT source")
        operands.accept(",")
        if source == WAIT_SOURCES["irq"]:
            index = irq_index(operands)
        else:
            index = operands.bounded("WAIT pin index", 0, 31)
        return (0b001 << 13) | (polarity << 7) | (source << 5) | index

    if mnemonic == "in":
        # [15:13] = 010, [12:8] = delay/side-set, [7:5] = source
        # (codes above; 100/101 reserved), [4:0] = bit count (32 -> 00000).
        source = operands.choice(IN_SOURCES, "IN source")
        operands.accept(",")
        count = operands.bounded("IN bit count", 1, 32)
        return (0b010 << 13) | (source << 5) | (count & 0x1F)

    if mnemonic == "out":
        # [15:13] = 011, [12:8] = delay/side-set, [7:5] = destination
        # (codes above), [4:0] = bit count (32 -> 00000).
        destination = operands.choice(OUT_DESTINATIONS, "OUT destination")
        operands.accept(",")
        count = operands.bounded("OUT bit count", 1, 32)
        return (0b011 << 13) | (destination << 5) | (count & 0x1F)

    if mnemonic == "push":
        # [15:13] = 100, [12:8] = delay/side-set, [7] = 0 (PUSH),
        # [6] = IFFULL (only push at the ISR shift threshold),
        # [5] = BLOCK (stall on full RX FIFO), [4:0] = 00000.
        if_full = operands.accept("iffull")
        block = blocking_flag(operands)
        return (0b100 << 13) | (int(if_full) << 6) | (block << 5)

    if mnemonic == "pull":
        # [15:13] = 100, [12:8] = delay/side-set, [7] = 1 (PULL),
        # [6] = IFEMPTY (only pull at the OSR shift threshold),
        # [5] = BLOCK (stall on empty TX FIFO), [4:0] = 00000.
        # A nonblocking pull from an empty TX FIFO copies X into the OSR.
        if_empty = operands.accept("ifempty")
        block = blocking_flag(operands)
        return (0b100 << 13) | (1 << 7) | (int(if_empty) << 6) | (block << 5)

    if mnemonic == "mov":
        # [15:13] = 101, [12:8] = delay/side-set, [7:5] = destination,
        # [4:3] = operation (00 copy, 01 invert, 10 reverse, 11 reserved),
        # [2:0] = source (source/destination codes are listed above).
        destination = operands.choice(MOV_DESTINATIONS, "MOV destination")
        operands.accept(",")
        operation = 0b00
        if operands.peek() in MOV_OPERATIONS:
            operation = operands.choice(MOV_OPERATIONS, "MOV operation")
        source = operands.choice(MOV_SOURCES, "MOV source")
        return (0b101 << 13) | (destination << 5) | (operation << 3) | source

    if mnemonic == "irq":
        # IRQ is reserved for future use. Accept its RP2040 operands and emit
        # NOP (MOV Y, Y). The caller still packs delay and side-set into [12:8].
        if operands.peek().lower() in IRQ_MODES:
            operands.take("IRQ mode")
        irq_index(operands)
        return NOP

    if mnemonic == "set":
        # [15:13] = 111, [12:8] = delay/side-set, [7:5] = destination
        # (000 PINS, 001 X, 010 Y, 100 PINDIRS), [4:0] = immediate data.
        destination = operands.choice(SET_DESTINATIONS, "SET destination")
        operands.accept(",")
        data = operands.bounded("SET immediate", 0, 31)
        return (0b111 << 13) | (destination << 5) | data

    if mnemonic == "nop":
        # Pseudoinstruction MOV Y, Y: [15:13] = 101, [12:8] = delay/side-set,
        # [7:5] = 010 (Y), [4:3] = 00 (copy), [2:0] = 010 (Y).
        return NOP

    raise operands.fail(f"unknown instruction {mnemonic!r}")


def blocking_flag(operands: Operands) -> int:
    if operands.accept("noblock"):
        return 0
    operands.accept("block")
    return 1  # PUSH and PULL both default to blocking.


def validate_control_flow(instructions, words, max_lines, wrap_bottom, wrap_top):
    # Mark explicit PC writes as jumps as well. Their destinations come from
    # runtime values, so only a JMP instruction supplies a static target.
    jumps = set()
    direct_jumps = {}
    for address, ((mnemonic, _), word) in enumerate(zip(instructions, words)):
        if mnemonic == "jmp":
            jumps.add(address)
            target = word & 0x1F                    # JMP [4:0]
            conditional = ((word >> 5) & 0x7) != 0  # JMP [7:5]
            direct_jumps[address] = (target, conditional)
        elif (mnemonic in ("mov", "out") and
              ((word >> 5) & 0x7) == 0b101):        # MOV/OUT destination PC
            jumps.add(address)

    # Follow known paths from the entry point. Conditional JMPs can take
    # either path, and unused instruction slots behave as NOPs.
    pending = [0]
    visited = set()
    while pending:
        address = pending.pop()
        if address in visited:
            continue
        visited.add(address)

        if address in jumps:
            if address not in direct_jumps:
                continue  # A computed PC write has no static successor.
            target, conditional = direct_jumps[address]
            pending.append(target)
            if not conditional:
                continue

        next_address = wrap_bottom if address == wrap_top else address + 1
        if next_address == max_lines:
            message = (
                f"fall-through from address {address} enters protected config memory "
                f"at address {max_lines} (hex row {max_lines + 1})"
            )
            if address < len(instructions):
                _, operands = instructions[address]
                raise operands.fail(message)
            raise ValueError(message)
        pending.append(next_address)


def assemble(source, max_lines=MAX_INSTRUCTION_WORDS):
    if not 1 <= max_lines <= MAX_INSTRUCTION_WORDS:
        raise ValueError(f"max_lines must be 1..{MAX_INSTRUCTION_WORDS}")

    labels = {}
    instructions = []
    register_overrides = {}
    program_name = None
    side_set = None
    wrap_bottom = None
    wrap_top = None

    # First pass: labels and wrap directives use zero-based instruction addresses.
    lines = re.sub(
        r";[^\n]*|//[^\n]*|/\*.*?\*/",
        lambda comment: re.sub(r"[^\n]", " ", comment[0]),
        source,
        flags=re.DOTALL,
    )
    for number, line in enumerate(lines.splitlines(), 1):
        line = line.strip()
        while (match := LABEL.match(line)) is not None:
            name = match[1]
            if name in labels:
                raise ValueError(f"line {number}: duplicate label {name!r}")
            labels[name] = len(instructions)
            line = line[match.end():].lstrip()
        if not line:
            continue

        operands = Operands(line, number, labels)
        mnemonic = operands.take("instruction or directive").lower()
        if mnemonic in REGISTER_DIRECTIVES:
            register = REGISTER_DIRECTIVES[mnemonic]
            if register in register_overrides:
                raise operands.fail(f"duplicate {mnemonic} directive")
            value = operands.take("an eight-digit hexadecimal register value")
            if not CONFIG_VALUE.fullmatch(value):
                raise operands.fail(f"{mnemonic} expects exactly eight hex digits, got {value!r}")
            register_overrides[register] = int(value, 16)
        elif mnemonic == ".program":
            if program_name is not None or instructions:
                raise operands.fail("one .program is allowed before the instructions")
            program_name = operands.take("program name")
            if not IDENTIFIER.fullmatch(program_name):
                raise operands.fail(f"invalid program name {program_name!r}")
        elif mnemonic == ".side_set":
            if side_set is not None or instructions:
                raise operands.fail(".side_set must appear once, before the instructions")
            count = operands.bounded("side-set width", 0, 5)
            optional = operands.accept("opt")
            pindirs = operands.accept("pindirs")
            if optional and not 1 <= count <= 4:
                raise operands.fail("optional side-set requires 1..4 data bits")
            side_set = SideSet(count, optional, pindirs)
        elif mnemonic == ".wrap_target":
            if wrap_bottom is not None:
                raise operands.fail("duplicate .wrap_target")
            wrap_bottom = len(instructions)
        elif mnemonic == ".wrap":
            if wrap_top is not None or not instructions:
                raise operands.fail(".wrap must appear once, after an instruction")
            wrap_top = len(instructions) - 1
        elif mnemonic.startswith("."):
            raise operands.fail(f"unsupported directive {mnemonic!r}")
        else:
            if len(instructions) == max_lines:
                raise operands.fail(f"program exceeds {max_lines} instruction slots")
            instructions.append((mnemonic, operands))
            continue
        operands.finish()

    if not instructions:
        raise ValueError("program contains no instructions")
    if wrap_bottom is not None and wrap_bottom >= len(instructions):
        raise ValueError(".wrap_target must precede an instruction")

    # Wrap is always enabled. A missing endpoint uses the corresponding edge
    # of the instruction slots, including any NOP padding before the config.
    if wrap_bottom is None:
        wrap_bottom = 0
    if wrap_top is None:
        wrap_top = max_lines - 1
    if wrap_bottom > wrap_top:
        raise ValueError(".wrap_target must precede .wrap")

    # Second pass: resolve forward JMP labels and encode the instruction words.
    side_set = side_set or SideSet()
    words = []
    for mnemonic, operands in instructions:
        word = encode_instruction(mnemonic, operands, max_lines)
        word |= side_set.encode(operands)
        operands.finish()
        words.append(word)

    validate_control_flow(instructions, words, max_lines, wrap_bottom, wrap_top)

    # Keep register order fixed for the boot FSM. Updating existing dictionary
    # keys preserves their order regardless of where the directives appeared.
    registers = REGISTER_DEFAULTS.copy()
    registers.update(register_overrides)

    # EXECCTRL [30] = SIDE_EN, [29] = SIDE_PINDIR, [16:12] = WRAP_TOP,
    # [11:7] = WRAP_BOTTOM. Both addresses are inclusive and zero-based.
    # The FSM wraps after WRAP_TOP even if both fields are zero.
    # Clear derived fields first so assembly can also override ones with zeros.
    registers["EXECCTRL"] &= ~((0b11 << 29) | (0x1F << 12) | (0x1F << 7))
    registers["EXECCTRL"] |= (
        (int(side_set.optional) << 30) | (int(side_set.pindirs) << 29)
        | (wrap_top << 12) | (wrap_bottom << 7)
    )
    # PINCTRL [31:29] includes the optional side-set enable bit.
    registers["PINCTRL"] &= ~(0b111 << 29)
    registers["PINCTRL"] |= side_set.total_bits << 29
    return words, registers, wrap_bottom, wrap_top


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", type=Path, help="default: input with .hex")
    parser.add_argument("--max-lines", type=int, default=MAX_INSTRUCTION_WORDS,
                        help="instruction slots before the config words (default: 32)")
    parser.add_argument("--halfword-order", choices=("low-first", "high-first"),
                        default="low-first",
                        help="order of each 32-bit register's halves (default: low-first)")
    parser.add_argument("--show-config", action="store_true", help="print boot config as JSON")
    args = parser.parse_args()
    output = args.output or args.input.with_suffix(".hex")

    try:
        if args.input.resolve() == output.resolve():
            raise ValueError("the input and output must be different files")
        words, registers, wrap_bottom, wrap_top = assemble(
            args.input.read_text(encoding="utf-8"), args.max_lines
        )
        image = words + [NOP] * (args.max_lines - len(words))
        register_config = {}
        for name, value in registers.items():
            halves = [value & 0xFFFF, value >> 16]
            if args.halfword_order == "high-first":
                halves.reverse()
            register_config[name] = {
                "value": f"0x{value:08X}",
                "hex_lines": [len(image) + 1, len(image) + 2],
                "halfwords": [f"{half:04X}" for half in halves],
            }
            image.extend(halves)

        output.write_text("".join(f"{word:04X}\n" for word in image), encoding="ascii")
        if args.show_config:
            print(json.dumps({
                "instruction_count": len(words),
                "instruction_slots": args.max_lines,
                "boot_address": args.max_lines,
                "halfword_order": args.halfword_order,
                "wrap_enabled": True,
                "wrap_bottom": wrap_bottom,
                "wrap_top": wrap_top,
                "sideset_count": registers["PINCTRL"] >> 29,
                "side_en": bool(registers["EXECCTRL"] & (1 << 30)),
                "side_pindir": bool(registers["EXECCTRL"] & (1 << 29)),
                "registers": register_config,
            }, indent=2))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{args.input}: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
