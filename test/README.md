# Simulation tests

The project and its modules use SystemVerilog stimulus and checks by default. [cocotb](https://docs.cocotb.org/en/stable/) is available with `FLOW=cocotb`. Run the commands below from `test/` inside the development container.

## Setup

1. Set `PROJECT_SOURCES` in [Makefile](Makefile) to your top level Verilog files.
2. Update the DUT instance in [tb.v](tb.v) to match your top level module.

## Module-level simulations

For a module named `fifo`, place its RTL at `src/modules/fifo.sv` and its testbench at `test/modules/tb_fifo.sv`. Run its SystemVerilog test with:

```sh
make sim_tb_fifo
```

To produce a VCD waveform, pass `FST=`:

```sh
make sim_tb_fifo FST=
```

FST is the default format. Separate compiled executables for VCD and FST are cached under `../sim_outputs/modules/sv/`. Within each format, the executable is rebuilt only when the testbench or RTL changes; the simulation runs on every invocation.

For a cocotb module test, add `test/modules/test_fifo.py` and run:

```sh
make cocotb_tb_fifo
```

Each module cocotb run uses its matching `tb_<name>.sv`, `src/modules/<name>.sv`, and `test_<name>.py`. Its build, waveform, and results are under `../sim_outputs/modules/cocotb/<name>/`. `make FLOW=cocotb` runs all discovered module cocotb tests alongside the top level cocotb test.

## IHP 1P 64x16 SRAM

Instantiate `RM_IHPSG13_1P_64x16_c2` using the port names in
[`src/modules/RM_IHPSG13_1P_64x16_c2.sv`](../src/modules/RM_IHPSG13_1P_64x16_c2.sv).
Tie `A_DLY` to `1'b1`. `A_MEN` enables the macro; `A_WEN` and `A_REN` select
write and read on a rising `A_CLK` edge. With both set, the output receives
the new write data. `A_DOUT` holds its last value when no read occurs. Memory
and output contents are undefined until written/read.

Read timing: set `A_REN`, `A_MEN`, and `A_ADDR` before a rising `A_CLK` edge.
`A_DOUT` updates just after that edge and holds until another enabled read.
The model has a registered output, but does not add a second clock of delay
after the edge that accepts the read. A controller that registers `A_DOUT` on
clock edges will capture this value on the following edge.

The source file is a black box for synthesis. RTL and gate-level simulations
instead compile the supplied IHP wrapper and behavioral core in `test/ihp_sram`
with `FUNCTIONAL` defined. Keep the two views out of the same compilation unless
`FUNCTIONAL` is defined; otherwise their module names collide. The model files
are explicit Makefile inputs, so editing either causes a rebuild.

Run the SRAM testbench with:

```sh
make sim_tb_ihp_sram
```

`make` also runs it with the other module tests. To write another standalone
testbench, compile it with both files in `test/ihp_sram` and `-DFUNCTIONAL`.

## Top-level simulations

Run `make` to execute all discovered module SystemVerilog tests and the top level SystemVerilog test in `tb.v`:

```sh
make
```

To run the cocotb module tests and the top level Python test in `test.py`:

```sh
make FLOW=cocotb
```

Add `FST=` to either command to use VCD output. When changing the waveform format for an existing cocotb build, use `make -B FLOW=cocotb FST=` to recompile it with the new waveform filename. The Makefile defines `SV_TEST` only for SV runs, keeping HDL stimulus inactive during cocotb tests.

For gate level simulation, first harden the project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`. Then run `make GATES=yes` for the HDL testbench, or add `FLOW=cocotb` for the Python test.

All generated builds, waveforms, and results are stored under the repository root's ignored `sim_outputs/` directory. `sim_build` is cocotb's conventional directory for compiled simulator files; this Makefile redirects those files to `sim_outputs/`. A `test/sim_build/` directory from an older run is no longer used.

## Viewing waveforms

To view the default top level SystemVerilog waveform with GTKWave:

```sh
gtkwave ../sim_outputs/rtl/sv/tb.fst tb.gtkw
```

Or use Surfer:

```sh
surfer ../sim_outputs/rtl/sv/tb.fst
```

The FIFO SV VCD waveform is at `../sim_outputs/modules/sv/fifo.vcd` after running the VCD module command above.
