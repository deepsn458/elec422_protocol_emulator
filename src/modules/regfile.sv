///////////////////////////////////////////
// regfile.sv
//
// Created: 16 Oct 2026
// Modified: 
//
// Purpose: General Purpose 3-port register file used for both scratch registers and test pattern storage
//          Does 2 reads per cycle and/or 1 write per cycle
////////////////////////////////////////////////////////////////////////////////////////////////

module regfile #(
    parameter REG_WIDTH,
    parameter NUMREGS = 5,      // Note reg0 is reserved for value 0. Actual writable regs is NUMREGS-1
    parameter ADDR_WIDTH = (NUMREGS > 2) ? $clog2(NUMREGS) : 1
)(
    input  logic                    clk,
    input  logic                    w_en,                      // Write enable
    input  logic [ADDR_WIDTH-1:0]   src_reg_1, src_reg_2,      // Source registers to read from
    input  logic [ADDR_WIDTH-1:0]   dest_reg,                  // Destination register to write into
    input  logic [REG_WIDTH-1:0]    w_data,                    // Write data for port 3
    output logic [REG_WIDTH-1:0]    r_data_1, r_data_2);       // Read data for ports 1, 2

    logic [REG_WIDTH-1:0] rf[NUMREGS-1:1];
    integer i;

    // Three ported register file
    // Read src regs to ports combinationally (src_reg_1/r_data_1, src_reg_2/r_data_2)
    // Write to dest reg occurs on falling edge of clock
    // Register 0 hardwired to 0

    // IMPORTANT:
    // - No reset is done. Processor is expected to write a reg before reading,
    //   or loop through regfile at initialisation and zero all registers
    // - No out of bounds checking is done. Processor is expected not to write to or read
    //   from an out of bounds register (aka read reg7 if only 6 registers exist)

    always_ff @(negedge clk) begin
        if (w_en && (dest_reg != 0)) begin
            rf[dest_reg] <= w_data;
        end
    end

    // Combinational assignment of read outputs based on src_reg, tie reg0 read to zero
    assign r_data_1 = (src_reg_1 != 0) ? rf[src_reg_1] : 0;
    assign r_data_2 = (src_reg_2 != 0) ? rf[src_reg_2] : 0;
endmodule
