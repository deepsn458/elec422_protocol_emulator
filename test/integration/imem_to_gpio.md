# Integration: instruction mem to gpio

## test path: instruction mem ->  sm -> fifos -> gpio controller

**Background**

assembler_to_imem_pt1.md tested the assembler. This test wil focus on ensuring 
the state machine can interface with the insstruction memory, gpio controller, and fifos.
The current tb_sm_no_smx_instr.sv executes a series of functional tests with a mock imem,
a mock gpio controller, and no actual fifos.

This test should use a testbench that actually instantiates the submodules and connects them
together. It should perform the same functional tests and verify the output.

**test procedure**

1. Use the assembler.py to generate hex outputs using the test programs in test/integration/pio_programs

2. Create a tb stub that wires up the above modules

3. Preload imem with each of the hex outputs.

4. Perform the same checks that were done in tb_sm_no_smx_instr.sv (except the nets checked
 should be tied to the gpio controller and fifo now)
