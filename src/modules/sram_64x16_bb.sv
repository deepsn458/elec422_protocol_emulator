// IHP SG13G2 single-port 64-word x 16-bit SRAM interface.
// Synthesis sees this black box; simulation uses the IHP model in test/ihp_sram.
// Compile that model with FUNCTIONAL defined so this declaration is omitted.
`ifndef FUNCTIONAL
(* blackbox *)
module RM_IHPSG13_1P_64x16_c2 (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [5:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output wire [15:0] A_DOUT
);
endmodule
`endif
