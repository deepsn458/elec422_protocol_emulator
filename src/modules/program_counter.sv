///////////////////////////////////////////
// program_counter.sv
//
// Created: 24 Oct 2026
// Modified: 
//
// Purpose: Standard program counter module with parametrised address width, byte increment, and memory start offset.
//          Defaults are set for 6-bit memory address with 16 bit instructions, SRAM memory word widths of 2 bytes,
//          and a instruction memory offset of 0x000000.
////////////////////////////////////////////////////////////////////////////////////////////////
module program_counter #(
    parameter int unsigned MEM_ADDR_WIDTH = 6,                   // Address width
    parameter int unsigned BYTE_INCREMENT = 2,                   // This is the number of bytes per instruction
    parameter int unsigned SRAM_BYTE_WIDTH = 2,                  // This is the number of bytes per word in the SRAM module
    parameter logic [MEM_ADDR_WIDTH-1:0] MEM_START_OFFSET = '0   // Offset where instruction memory starts
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      pc_en,
    input  logic                      branch_en,
    input  logic [MEM_ADDR_WIDTH-1:0] branch_addr,

    output logic [MEM_ADDR_WIDTH-1:0] pc,      // clocked output
    output logic                      read_en  // combinational output
);

    // Determine increment in address needed
    localparam logic [MEM_ADDR_WIDTH-1:0] ADDR_INCREMENT =
        MEM_ADDR_WIDTH'(BYTE_INCREMENT / SRAM_BYTE_WIDTH);

    assign read_en = rst_n && pc_en;  // read enable active as long as pc is active

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= MEM_START_OFFSET;
        else if (pc_en) begin
            if (branch_en)
                pc <= branch_addr;
            else
                pc <= pc + ADDR_INCREMENT;
        end
    end

endmodule
