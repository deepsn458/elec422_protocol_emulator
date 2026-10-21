"""cocotb checks for the OSR module testbench."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

MASK32 = 0xFFFFFFFF


def bits_of(n):
    """The 5-bit count field encodes 32 as 0."""
    return 32 if n == 0 else n


def model_out(q, n, right):
    """Bits leaving on an OUT, right-aligned."""
    m = bits_of(n)
    if right:
        return q & ((1 << m) - 1)
    return q >> (32 - m)


def model_rest(q, n, right):
    """Bits left in the register after an OUT, zero filled."""
    m = bits_of(n)
    if right:
        return q >> m
    return (q << m) & MASK32


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
    dut.n.value = 0
    dut.dir.value = 0
    dut.din.value = 0


async def tick(dut):
    """Let one rising edge happen, then sample just after it."""
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def load(dut, value):
    await FallingEdge(dut.clk)
    idle(dut)
    dut.load.value = 1
    dut.din.value = value
    await tick(dut)
    assert int(dut.q.value) == value
    assert int(dut.cnt.value) == 0


async def shift(dut, n, right):
    """Do one OUT and return the bits that left."""
    await FallingEdge(dut.clk)
    idle(dut)
    dut.shift.value = 1
    dut.n.value = n
    dut.dir.value = int(right)
    q = int(dut.q.value)
    exp_out = model_out(q, n, right)
    exp_q = model_rest(q, n, right)
    exp_cnt = model_cnt(int(dut.cnt.value), n)
    await Timer(1, unit="ns")
    out = int(dut.shifted.value)
    assert out == exp_out, f"shifted {out:08x} != {exp_out:08x}"
    assert int(dut.shift_cnt.value) == exp_cnt
    await tick(dut)
    assert int(dut.q.value) == exp_q, f"q {int(dut.q.value):08x} != {exp_q:08x}"
    assert int(dut.cnt.value) == exp_cnt
    return out


@cocotb.test()
async def test_osr_directed(dut):
    await setup(dut)
    # Reset marks the OSR empty so the first OUT with autopull refills it.
    assert int(dut.q.value) == 0
    assert int(dut.cnt.value) == 32

    # Spec examples: right shift sends the low bits, left shift the high bits.
    await load(dut, 0x12345678)
    assert await shift(dut, 8, right=True) == 0x78
    assert int(dut.q.value) == 0x00123456
    await load(dut, 0x12345678)
    assert await shift(dut, 8, right=False) == 0x12
    assert int(dut.q.value) == 0x34567800

    # n = 0 sends all 32 bits and empties the register.
    await load(dut, 0xCAFEF00D)
    assert await shift(dut, 0, right=True) == 0xCAFEF00D
    assert int(dut.q.value) == 0
    assert int(dut.cnt.value) == 32

    # UART-style transmit: 0x5A goes out LSB first.
    await load(dut, 0x5A)
    sent = [await shift(dut, 1, right=True) for _ in range(8)]
    assert sent == [(0x5A >> i) & 1 for i in range(8)]
    assert int(dut.cnt.value) == 8

    # SPI-style transmit: 0xA5 in the top byte goes out MSB first.
    await load(dut, 0xA5000000)
    sent = [await shift(dut, 1, right=False) for _ in range(8)]
    assert sent == [(0xA5 >> (7 - i)) & 1 for i in range(8)]

    # The count saturates at 32.
    await load(dut, MASK32)
    await shift(dut, 20, right=True)
    await shift(dut, 20, right=True)
    assert int(dut.cnt.value) == 32


@cocotb.test()
async def test_osr_control(dut):
    await setup(dut)

    # Load wins over shift in the same cycle.
    await load(dut, 0xAAAAAAAA)
    await shift(dut, 4, right=True)
    await FallingEdge(dut.clk)
    idle(dut)
    dut.load.value = 1
    dut.shift.value = 1
    dut.n.value = 4
    dut.din.value = 0x13579BDF
    await tick(dut)
    assert int(dut.q.value) == 0x13579BDF
    assert int(dut.cnt.value) == 0

    # With ce low, nothing changes.
    await load(dut, 0x22222222)
    await FallingEdge(dut.clk)
    dut.ce.value = 0
    idle(dut)
    dut.shift.value = 1
    dut.n.value = 4
    await tick(dut)
    await FallingEdge(dut.clk)
    idle(dut)
    dut.load.value = 1
    await tick(dut)
    assert int(dut.q.value) == 0x22222222
    assert int(dut.cnt.value) == 0

    # With ce high but no strobe, the register holds.
    await FallingEdge(dut.clk)
    dut.ce.value = 1
    idle(dut)
    await tick(dut)
    assert int(dut.q.value) == 0x22222222
    assert int(dut.cnt.value) == 0

    # Reset in the middle of a run.
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    await tick(dut)
    assert int(dut.q.value) == 0
    assert int(dut.cnt.value) == 32


@cocotb.test()
async def test_osr_random(dut):
    await setup(dut)
    rng = random.Random(422)
    for _ in range(2000):
        if rng.randrange(8) == 0:
            await load(dut, rng.getrandbits(32))
        else:
            await shift(dut, rng.randrange(32), rng.randrange(2) == 1)
