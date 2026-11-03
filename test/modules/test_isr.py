"""cocotb checks for the ISR module testbench."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

MASK32 = 0xFFFFFFFF


def bits_of(n):
    """The 5-bit count field encodes 32 as 0."""
    return 32 if n == 0 else n


def model_shift(q, src, n, right):
    m = bits_of(n)
    src &= (1 << m) - 1
    if right:
        return ((q >> m) | (src << (32 - m))) & MASK32
    return ((q << m) | src) & MASK32


def model_cnt(cnt, n):
    return min(cnt + bits_of(n), 32)


async def setup(dut):
    dut.rst.value = 1
    dut.ce.value = 1
    idle(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


def idle(dut):
    dut.load.value = 0
    dut.shift.value = 0
    dut.load_cnt.value = 0
    dut.n.value = 0
    dut.dir.value = 0
    dut.din.value = 0


async def tick(dut):
    """Let one rising edge happen, then sample just after it."""
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def load(dut, value, count):
    await FallingEdge(dut.clk)
    idle(dut)
    dut.load.value = 1
    dut.din.value = value
    dut.load_cnt.value = count
    await tick(dut)
    assert int(dut.q.value) == value
    assert int(dut.cnt.value) == min(count, 32)


async def shift(dut, src, n, right):
    await FallingEdge(dut.clk)
    idle(dut)
    dut.shift.value = 1
    dut.din.value = src
    dut.n.value = n
    dut.dir.value = int(right)
    exp_q = model_shift(int(dut.q.value), src, n, right)
    exp_cnt = model_cnt(int(dut.cnt.value), n)
    await Timer(1, unit="ns")
    assert int(dut.shift_q.value) == exp_q, f"shift_q {int(dut.shift_q.value):08x} != {exp_q:08x}"
    assert int(dut.shift_cnt.value) == exp_cnt
    await tick(dut)
    assert int(dut.q.value) == exp_q, f"q {int(dut.q.value):08x} != {exp_q:08x}"
    assert int(dut.cnt.value) == exp_cnt


@cocotb.test()
async def test_isr_directed(dut):
    await setup(dut)
    assert int(dut.q.value) == 0
    assert int(dut.cnt.value) == 0

    # Spec examples: left shift fills the bottom, right shift fills the top.
    await load(dut, 0x000000A5, 0)
    await shift(dut, 0xB, 4, right=False)
    assert int(dut.q.value) == 0x00000A5B
    await load(dut, 0xA5000000, 0)
    await shift(dut, 0xB, 4, right=True)
    assert int(dut.q.value) == 0xBA500000

    # n = 0 means 32 bits; source bits above n are ignored.
    await shift(dut, 0x01234567, 0, right=True)
    assert int(dut.q.value) == 0x01234567
    assert int(dut.cnt.value) == 32
    await load(dut, 0, 0)
    await shift(dut, 0xFFFFFFF5, 3, right=False)
    assert int(dut.q.value) == 0x5

    # UART-style receive: eight 1-bit right shifts put the byte in [31:24].
    await load(dut, 0, 0)
    for i in range(8):
        await shift(dut, (0x5A >> i) & 1, 1, right=True)
    assert int(dut.q.value) == 0x5A000000
    assert int(dut.cnt.value) == 8

    # Count saturation and load_cnt clamping.
    await load(dut, 0, 30)
    await shift(dut, 1, 5, right=False)
    assert int(dut.cnt.value) == 32
    await load(dut, 0, 40)


@cocotb.test()
async def test_isr_control(dut):
    await setup(dut)

    # Load wins over shift in the same cycle (autopush clears the ISR).
    await load(dut, 0xFF, 8)
    await FallingEdge(dut.clk)
    idle(dut)
    dut.load.value = 1
    dut.shift.value = 1
    dut.n.value = 8
    await tick(dut)
    assert int(dut.q.value) == 0
    assert int(dut.cnt.value) == 0

    # With ce low, nothing changes.
    await load(dut, 0x11111111, 4)
    await FallingEdge(dut.clk)
    dut.ce.value = 0
    idle(dut)
    dut.shift.value = 1
    dut.din.value = 0xF
    dut.n.value = 4
    await tick(dut)
    await FallingEdge(dut.clk)
    idle(dut)
    dut.load.value = 1
    await tick(dut)
    assert int(dut.q.value) == 0x11111111
    assert int(dut.cnt.value) == 4

    # With ce high but no strobe, the register holds.
    await FallingEdge(dut.clk)
    dut.ce.value = 1
    idle(dut)
    await tick(dut)
    assert int(dut.q.value) == 0x11111111
    assert int(dut.cnt.value) == 4

    # Reset in the middle of a run.
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    await tick(dut)
    assert int(dut.q.value) == 0
    assert int(dut.cnt.value) == 0


@cocotb.test()
async def test_isr_random(dut):
    await setup(dut)
    rng = random.Random(422)
    for _ in range(2000):
        if rng.randrange(8) == 0:
            await load(dut, rng.getrandbits(32), rng.randrange(41))
        else:
            await shift(dut, rng.getrandbits(32), rng.randrange(32), rng.randrange(2) == 1)
