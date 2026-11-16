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

