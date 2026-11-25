// sm_tb_common.svh - shared helpers for the SM integration testbenches
// (tb_sm_imem, tb_sm_tx_fifo, tb_sm_rx_fifo, tb_sm_gpio).
//
// `include it inside a testbench module. Pure localparams and functions
// only: instruction encoders (RP2040 datasheet table 366) and the
// configuration-register builders (RP2040 bit layout, plus FAULT_VEC in
// EXECCTRL[23:19]). Copied from test/modules/tb_sm_no_smx_instr.sv so the
// integration tests don't depend on the assembler.

// JMP conditions
localparam [2:0] C_ALWAYS = 0, C_NOT_X = 1, C_X_DEC = 2, C_NOT_Y = 3,
                 C_Y_DEC = 4, C_X_NE_Y = 5, C_PIN = 6, C_NOT_OSRE = 7;
// WAIT sources
localparam [1:0] W_GPIO = 0, W_PIN = 1, W_IRQ = 2;
// IN sources
localparam [2:0] IN_PINS = 0, IN_X = 1, IN_Y = 2, IN_NULL = 3, IN_ISR = 6, IN_OSR = 7;
// OUT destinations
localparam [2:0] O_PINS = 0, O_X = 1, O_Y = 2, O_NULL = 3, O_PINDIRS = 4,
                 O_PC = 5, O_ISR = 6;
// MOV destinations, operations and sources
localparam [2:0] MD_PINS = 0, MD_X = 1, MD_Y = 2, MD_PC = 5, MD_ISR = 6, MD_OSR = 7;
localparam [1:0] MOP_NONE = 0, MOP_INV = 1, MOP_REV = 2;
localparam [2:0] MS_PINS = 0, MS_X = 1, MS_Y = 2, MS_NULL = 3, MS_STATUS = 5,
                 MS_ISR = 6, MS_OSR = 7;
// SET destinations
localparam [2:0] S_PINS = 0, S_X = 1, S_Y = 2, S_PINDIRS = 4;

localparam [15:0] NOP = 16'hA042;   // mov y, y

function automatic [15:0] i_jmp(input [2:0] cond, input [4:0] addr);
    i_jmp = {3'b000, 5'd0, cond, addr};
endfunction
function automatic [15:0] i_wait(input pol, input [1:0] src, input [4:0] idx);
    i_wait = {3'b001, 5'd0, pol, src, idx};
endfunction
function automatic [15:0] i_in(input [2:0] src, input [5:0] n);    // n = 1..32
    i_in = {3'b010, 5'd0, src, n[4:0]};
endfunction
function automatic [15:0] i_out(input [2:0] dst, input [5:0] n);   // n = 1..32
    i_out = {3'b011, 5'd0, dst, n[4:0]};
endfunction
function automatic [15:0] i_push(input iffull, input blk);
    i_push = {3'b100, 5'd0, 1'b0, iffull, blk, 5'd0};
endfunction
function automatic [15:0] i_pull(input ifempty, input blk);
    i_pull = {3'b100, 5'd0, 1'b1, ifempty, blk, 5'd0};
endfunction
function automatic [15:0] i_mov(input [2:0] dst, input [1:0] op, input [2:0] src);
    i_mov = {3'b101, 5'd0, dst, op, src};
endfunction
function automatic [15:0] i_irq(input clr, input wt, input [4:0] idx);
    i_irq = {3'b110, 5'd0, 1'b0, clr, wt, idx};
endfunction
function automatic [15:0] i_set(input [2:0] dst, input [4:0] data);
    i_set = {3'b111, 5'd0, dst, data};
endfunction
// Fill in the delay/side-set field.
function automatic [15:0] dss(input [15:0] ins, input [4:0] field);
    dss = ins | {3'b000, field, 8'd0};
endfunction

function automatic [31:0] clkdiv_f(input [15:0] div_int, input [7:0] div_frac);
    clkdiv_f = {div_int, div_frac, 8'd0};
endfunction
function automatic [31:0] pinctrl_f(input [2:0] sideset_count, input [2:0] set_count,
                                    input [5:0] out_count, input [4:0] in_base,
                                    input [4:0] sideset_base, input [4:0] set_base,
                                    input [4:0] out_base);
    pinctrl_f = {sideset_count, set_count, out_count, in_base, sideset_base, set_base, out_base};
endfunction
// status_sel: 0 = TX FIFO level, 1 = RX FIFO level (MOV x, STATUS is all
// ones when that level < status_n).
function automatic [31:0] execctrl_f(input side_en, input side_pindir, input [4:0] jmp_pin,
                                     input [4:0] fault_vec,
                                     input [4:0] wrap_top, input [4:0] wrap_bottom,
                                     input status_sel, input [3:0] status_n);
    execctrl_f = {1'b0, side_en, side_pindir, jmp_pin, fault_vec, 1'b0, 1'b0,
                  wrap_top, wrap_bottom, 2'd0, status_sel, status_n};
endfunction
function automatic [31:0] shiftctrl_f(input [4:0] pull_thresh, input [4:0] push_thresh,
                                      input out_right, input in_right,
                                      input autopull, input autopush);
    shiftctrl_f = {2'd0, pull_thresh, push_thresh, out_right, in_right, autopull, autopush, 16'd0};
endfunction
