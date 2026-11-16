We have 8 inputs 8 outputs and 8 bidirectional pins.

Trying to save as many bidirectional pins as possible because they are more useful than either input or output
Reserved

- clk (input)
- rst (input)
- vdd (input)
- gnd (input)
- spi interface for instruction mem (mux to fifos)(sclk: input . mosi: output. Miso: input. cs: input)

Total usage: 7 input, 1 output

Remaining:
7 output, 8 bidirectional, 1 input.

GPIO numberting
Pin 0: input
Pins 1-8: bidirectional
Pins 9-15: output

## Runtime Pin handling logic
1. GPIO controller takes 3 control signals signaling if the instr sets a pindir, performs a read, or a write
2. GPIO controller contains masks signalling which pins are output only, bidirectional, or input
3. Performs a combinational per-instruction check
```
assign invalid_dir =
    dir_write_en &&
    |(physical_dir_mask & ~BIDIR_CAPABLE);

assign invalid_output =
    output_write_en &&
    |(physical_output_mask & ~OUTPUT_CAPABLE);

assign invalid_input =
    input_read_en &&
    |(physical_input_mask & ~INPUT_CAPABLE);

assign gpio_fault =
    invalid_dir | invalid_output | invalid_input;
```
4. Feeds the gpio fault to the sm which handles (throws an exception)

This prevents us making the assembler from becoming a compiler by performing extensive pre-scanning and pre-mapping.

## Implementation (`gpio_controller.sv`)
- Pin types are parameters: `IN_ONLY`, `BIDIR`, `OUT_ONLY` (must not overlap), plus `SAFE_OUT`, the output level at reset and while faulted.
- The SM's own masks are the enables: `pins_we`/`dirs_we` (OUT, SET, MOV PINS, side-set) and `pins_re` (IN PINS, WAIT GPIO/PIN, JMP PIN). `MOV x, PINS` reads all pins and is not checked; unreadable pins read as 0.
- `gpio_fault` is combinational and per-cycle. The SM branches to `FAULT_VEC` (EXECCTRL[23:19]) that same cycle, and none of that cycle's writes land.
- The sticky `fault` flag (plus `fault_cause` = {read, dir, drive}) then releases every bidirectional pad, holds output pads at `SAFE_OUT`, and ignores further writes. Pads change only on clock edges, so they don't glitch on the fault.
- Only `rst` or the host's `clr_fault` pulse clears it; both also reset the pin registers.

