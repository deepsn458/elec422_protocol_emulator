# Simulation tests

The project and its modules can be tested with [cocotb](https://docs.cocotb.org/en/stable/) or with stimulus and checks written in the HDL testbench. Run the commands below from `test/` inside the development container.

## Setup

1. Set `PROJECT_SOURCES` in [Makefile](Makefile) to your top level Verilog files.
2. Update the DUT instance in [tb.v](tb.v) to match your top level module.

## Module-level simulations

For a module named `fifo`, place its RTL at `src/modules/fifo.sv` and its testbench at `test/modules/tb_fifo.sv`. To run the SystemVerilog stimulus and checks and produce a VCD waveform:

```sh
make sim_tb_fifo FLOW=sv FST=
```

Pass `FLOW=sv` for this SV run and `FST=` for VCD output. Leaving `FST` at its default produces an FST waveform. Separate compiled executables for VCD and FST are cached under `../sim_outputs/modules/sv/`. Within each format, the executable is rebuilt only when the testbench or RTL changes; the simulation runs on every invocation.

For a cocotb module test, add `test/modules/test_fifo.py` and run:

```sh
make cocotb_tb_fifo
```

Each module cocotb run uses its matching `tb_<name>.sv`, `src/modules/<name>.sv`, and `test_<name>.py`. Its build, waveform, and results are under `../sim_outputs/modules/cocotb/<name>/`.

## Top-level simulations

Run `make` to execute all discovered module tests and the top level cocotb test in `test.py`:

```sh
make
```

To run the stimulus and checks in `tb.v` instead of the top level cocotb test:

```sh
make FLOW=sv
```

Add `FST=` to use VCD output. If switching a previously compiled top level run between FST and VCD, use `make -B FLOW=sv FST=` to recompile it with the new waveform filename. The Makefile defines `SV_TEST` only for SV runs, keeping HDL stimulus inactive during cocotb tests.

For gate level simulation, first harden the project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`. Then run `make GATES=yes`, with `FLOW=sv` if you want the HDL testbench.

All generated builds, waveforms, and results are stored under the repository root's ignored `sim_outputs/` directory. `sim_build` is cocotb's conventional directory for compiled simulator files; this Makefile redirects those files to `sim_outputs/`. A `test/sim_build/` directory from an older run is no longer used.

## Viewing waveforms

To view the default top level cocotb waveform with GTKWave:

```sh
gtkwave ../sim_outputs/rtl/cocotb/tb.fst tb.gtkw
```

Or use Surfer:

```sh
surfer ../sim_outputs/rtl/cocotb/tb.fst
```

The FIFO SV VCD waveform is at `../sim_outputs/modules/sv/fifo.vcd` after running the module command above.
