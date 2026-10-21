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

Each module cocotb run uses its matching `tb_<name>.sv` and `test_<name>.py`. Its build, waveform, and results are under `../sim_outputs/modules/cocotb/<name>/`. `make FLOW=cocotb` runs all discovered module cocotb tests alongside the top level cocotb test.

Both module flows compile every `src/modules/*.sv` file, so a module can instantiate others (for example, `sm` uses `isr`, `osr`, `regfile` and `clockdiv`); `src/modules/<name>.sv` must still exist.

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
