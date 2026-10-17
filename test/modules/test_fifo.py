"""cocotb checks for the FIFO module testbench."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


@cocotb.test()
async def test_fifo(dut):
    dut.rst.value = 1
    dut.d_in.value = 0
    dut.w_en.value = 0
    dut.r_en.value = 0
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    assert int(dut.wptr.value) == 0
    assert int(dut.rptr.value) == 0

    dut.r_en.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.rptr.value) == 0

    await FallingEdge(dut.clk)
    dut.r_en.value = 0
    dut.w_en.value = 1
    dut.d_in.value = 0x12345678
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.wptr.value) == 1

    await FallingEdge(dut.clk)
    dut.w_en.value = 0
    dut.d_in.value = 0x87654321
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.wptr.value) == 1

    await FallingEdge(dut.clk)
    dut.r_en.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.d_out.value) == 0x12345678
    assert int(dut.rptr.value) == 1

    await FallingEdge(dut.clk)
    dut.r_en.value = 0
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    for value in range(4):
        await FallingEdge(dut.clk)
        dut.w_en.value = 1
        dut.d_in.value = value
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert int(dut.wptr.value) == value + 1

    await FallingEdge(dut.clk)
    dut.d_in.value = 0xDEADBEEF
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.wptr.value) == 4
