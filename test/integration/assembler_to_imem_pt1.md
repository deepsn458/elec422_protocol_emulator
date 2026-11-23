# Assembler to Instruction memory verification pt 1: hex generation

## Test Objective: verify the assembler produces the correct hex for each program

**Create a python program that performs the following steps `test\integration\assembler_test.py`**
1. Create a 'golden' hex file for each program that contains the hex values for the programs in  
    tb_no_smx_instr.sv.

    These are the programs from `test_set_and_wrap` to `test_pins_re`. Append the config values
    at the end of each program

    Store the golden pio programs in `test/integration/assembler_test_outputs/golden`

2. Create 'pio assembly' `.pio` versions of the above programs and store them in `test/integration/assember_test_outputs/generated`

3. Compare each file on turn and verify each line is identical

4. Generate a log file. One program each line, pass if the programs are identical and fail if not.
 If it's a fail, the program comparison will take more lines. The lines below fail should contain which instructions
 were generated incorrectly. This output should also be in `assembler_test_outputs`

5. Everything in the `assembler_test_outputs` directory should be in the gitignore




    
 
