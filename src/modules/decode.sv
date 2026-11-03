// decode - instruction decoder for one PIO state machine
//
//   * Splits a 16-bit PIO instruction into its fields:
//       [15:13] opcode, [12:8] delay/side-set, [7:5] arg1, [4:0] arg2
//   * One is_* flag per instruction (PUSH and PULL share opcode 4 and
//     differ in bit 7).
//   * Named control bits (Block, IfFull/IfEmpty, IRQ Clear/Wait, MOV op and
//     source, WAIT source and polarity) so later logic avoids bit selects.
//   * Splits the delay/side-set field using SIDESET_COUNT and SIDE_EN:
//     the top sideset_count bits are side-set, the rest delay. With SIDE_EN
//     the top side-set bit is an enable, leaving one fewer data bit.
//     ss_value is right-aligned; mapping it onto GPIOs is left to the caller.
//   * irq_idx applies relative IRQ addressing: if bit 4 of the index is set,
//     SM_ID is added to bits 1:0 (modulo 4).
//
// Purely combinational.

`default_nettype none

module decode #(
  parameter logic [1:0] SM_ID = 2'd0      // state machine number, for IRQ rel
) (
  input  logic [15:0] ins,
  input  logic [2:0]  sideset_count,      // PINCTRL.SIDESET_COUNT, 0..5
  input  logic        side_en,            // EXECCTRL.SIDE_EN

  // Fields
  output logic [2:0]  arg1,               // destination / condition / source
  output logic [4:0]  arg2,               // bit count / address / data / index
  output logic [5:0]  bit_count,          // IN/OUT bit count, 1..32 (0 encodes 32)

  // Instruction type
  output logic        is_jmp,
  output logic        is_wait,
  output logic        is_in,
  output logic        is_out,
  output logic        is_push,
  output logic        is_pull,
  output logic        is_mov,
  output logic        is_irq,
  output logic        is_set,

  // Control bits
  output logic        blk,                // PUSH/PULL Block
  output logic        if_flag,            // PUSH IfFull / PULL IfEmpty
  output logic        irq_clr_bit,        // IRQ Clear
  output logic        irq_wait_bit,       // IRQ Wait
  output logic [1:0]  mov_op,             // 0 none, 1 invert, 2 bit-reverse
  output logic [2:0]  mov_srcsel,         // MOV source
  output logic [1:0]  wait_src,           // WAIT source: 0 GPIO, 1 PIN, 2 IRQ
  output logic        wait_pol,           // WAIT polarity

  // Delay / side-set
  output logic [4:0]  delay,              // delay cycles after the instruction
  output logic        ss_valid,           // this instruction performs a side-set
  output logic [2:0]  ss_bits,            // side-set data bits, 0..5
  output logic [4:0]  ss_value,           // side-set data, right-aligned

  // IRQ index (WAIT IRQ and IRQ)
  output logic [2:0]  irq_idx,
  output logic [7:0]  irq_bit             // one-hot irq_idx
);

  // Opcodes
  localparam logic [2:0] OP_JMP  = 3'd0;
  localparam logic [2:0] OP_WAIT = 3'd1;
  localparam logic [2:0] OP_IN   = 3'd2;
  localparam logic [2:0] OP_OUT  = 3'd3;
  localparam logic [2:0] OP_PP   = 3'd4;   // PUSH (bit 7 = 0) / PULL (bit 7 = 1)
  localparam logic [2:0] OP_MOV  = 3'd5;
  localparam logic [2:0] OP_IRQ  = 3'd6;
  localparam logic [2:0] OP_SET  = 3'd7;

  logic [2:0] op;
  logic [4:0] dss;
  logic [4:0] ss_field;          // all side-set bits incl. enable, right-aligned

  assign op   = ins[15:13];
  assign dss  = ins[12:8];
  assign arg1 = ins[7:5];
  assign arg2 = ins[4:0];

  assign bit_count = (arg2 == 5'd0) ? 6'd32 : {1'b0, arg2};

  assign is_jmp  = (op == OP_JMP);
  assign is_wait = (op == OP_WAIT);
  assign is_in   = (op == OP_IN);
  assign is_out  = (op == OP_OUT);
  assign is_push = (op == OP_PP) && !ins[7];
  assign is_pull = (op == OP_PP) &&  ins[7];
  assign is_mov  = (op == OP_MOV);
  assign is_irq  = (op == OP_IRQ);
  assign is_set  = (op == OP_SET);

  assign if_flag      = ins[6];
  assign blk          = ins[5];
  assign irq_clr_bit  = ins[6];
  assign irq_wait_bit = ins[5];
  assign mov_op       = ins[4:3];
  assign mov_srcsel   = ins[2:0];
  assign wait_src     = ins[6:5];
  assign wait_pol     = ins[7];

  assign delay    = dss & (5'h1F >> sideset_count);
  assign ss_field = dss >> (3'd5 - sideset_count);
  assign ss_valid = (sideset_count != 3'd0) &&
                    (!side_en || ss_field[sideset_count - 3'd1]);
  assign ss_bits  = (side_en && sideset_count != 3'd0) ? sideset_count - 3'd1
                                                       : sideset_count;
  assign ss_value = ss_field & ((5'd1 << ss_bits) - 5'd1);

  assign irq_idx = arg2[4] ? {arg2[2], arg2[1:0] + SM_ID} : arg2[2:0];
  assign irq_bit = 8'd1 << irq_idx;

endmodule

`default_nettype wire
