`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_uart.fst"
`endif

// Full-duplex UART on ONE sm_no_smx_instr (DATA_WIDTH = 8).
//
// One state machine transmits on GPIO TXP and receives on GPIO RXP at the
// same time. The RX pin is either looped back from the TX pin or driven by
// the testbench, playing an external device. Pins that nothing drives read
// high (UART idle, as with a pull-up).
//
// How one SM does both directions
// -------------------------------
// A UART bit is 3 "slots" of 4 SM cycles (12 cycles per bit). EVERY slot
// starts with the same two TX instructions:
//     pull ifempty noblock    ; next TX word when the current one is used up
//     out pins, 1             ; drive one third of a bit onto TX
// and uses its remaining cycles for one RX step (poll the line, sample a
// bit, count bits, ...). Because every slot does the same TX work, the RX
// code can start a frame in any slot without disturbing TX timing, so RX
// lines up with the external start bit to within one slot (1/3 bit), with
// no TX/RX phase relationship needed.
//
// That needs TX to output one third of a bit per slot, so the host pre-frames
// each byte: start bit, 8 data bits (LSB first), stop bit, each repeated 3
// times = 30 bits, padded with two 1s to 32 (frame_word). That is written to
// the TX FIFO as 4 bytes, low byte first; PULL_THRESH = 8. The host writes
// all 4 at once, only when the FIFO is empty, so the next 8 bits are always
// there when the OSR runs out mid-frame. When the FIFO is empty between
// frames, "pull noblock" copies X, which holds all ones, so the line idles
// high. The 2 padding bits make the stop bit 2/3 of a bit longer. Nothing ever blocks: a blocking PULL/PUSH would stop the
// other direction.
//
// RX samples each bit 4 slots (1.33 bits) after the slot in which it saw the
// start bit, then every 3 slots, so samples land 1/3..2/3 of the way through
// each bit. A low stop bit sets IRQ flag 4 rel, pushes nothing, and waits
// for the line to go high again (still transmitting). The received byte is
// the whole 8-bit RX FIFO word.

module tb_sm_uart;
    localparam int W = 8;               // DATA_WIDTH: X, Y, ISR, OSR, FIFO words, GPIOs
    localparam int TXP = 6;             // TX pin
    localparam int RXP = 2;             // RX pin
    localparam [1:0] SM_ID = 2'd0;
    localparam int ERR_FLAG = 4 + SM_ID; // irq 4 rel
    localparam int BIT = 12;            // SM cycles per UART bit (3 slots x 4)
    localparam int PAD = 8;             // extra idle SM cycles after each frame (2 padding slots)

    reg clk;
    reg rst;
    reg en;
    reg [31:0] clkdiv, execctrl, shiftctrl, pinctrl;

    wire [5:0] mem_addr;                // next PC, to the synchronous memory
    wire [5:0] pc = dut.pc;             // the current PC, for checks
    wire read_en;
    wire [W-1:0] tx_data;
    wire tx_empty;
    wire [2:0] tx_level;
    wire tx_pop;
    wire [W-1:0] rx_data;
    wire rx_full;
    wire [2:0] rx_level;
    wire rx_push;
    wire [W-1:0] pins_we, pins_wdata, dirs_we, dirs_wdata;
    wire [W-1:0] gpio_in;
    reg [7:0] irq_flags;
    wire [7:0] irq_set, irq_clr;

    // Instruction memory with a synchronous read, like the IHP SRAM: the
    // address is registered on the clock edge and the word comes out after
    // it. 0-31 hold the program, 32-39 the config words the SM loads at boot
    // (see reset_all).
    reg [15:0] imem [0:63];
    reg [15:0] instr;
    always @(posedge clk)
        if (read_en)
            instr <= imem[mem_addr];

    sm_no_smx_instr #(.SM_ID(SM_ID), .DATA_WIDTH(W)) dut (
        .clk(clk),
        .external_rst(rst),
        .imem_loaded(1'b1),               // memory is preloaded by the tb
        .en(en),
        .restart(1'b0),
        .clkdiv_restart(1'b0),
        .mem_addr(mem_addr),
        .read_en(read_en),
        .instr(instr),
        .tx_data(tx_data),
        .tx_empty(tx_empty),
        .tx_level(tx_level),
        .tx_pop(tx_pop),
        .rx_data(rx_data),
        .rx_full(rx_full),
        .rx_level(rx_level),
        .rx_push(rx_push),
        .gpio_in(gpio_in),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .irq_flags(irq_flags),
        .irq_set(irq_set),
        .irq_clr(irq_clr)
    );

    // ------------------------------------------------------------------------
    // Models of the blocks around the state machine
    // ------------------------------------------------------------------------

    // 4-deep first-word fall-through TX FIFO, written by the host.
    reg [W-1:0] txf [0:3];
    reg [1:0] tx_rd, tx_wr;
    reg [2:0] tx_cnt;
    reg host_tx_we;
    reg [W-1:0] host_tx_wdata;
    assign tx_data = txf[tx_rd];
    assign tx_empty = (tx_cnt == 3'd0);
    assign tx_level = tx_cnt;
    always @(posedge clk) begin
        if (rst) begin
            tx_rd <= 0;
            tx_wr <= 0;
            tx_cnt <= 0;
        end else begin
            if (host_tx_we) begin
                txf[tx_wr] <= host_tx_wdata;
                tx_wr <= tx_wr + 2'd1;
            end
            if (tx_pop)
                tx_rd <= tx_rd + 2'd1;
            tx_cnt <= tx_cnt + {2'd0, host_tx_we} - {2'd0, tx_pop};
        end
    end

    // 4-deep RX FIFO, read by the host.
    reg [W-1:0] rxf [0:3];
    reg [1:0] rx_rd, rx_wr;
    reg [2:0] rx_cnt;
    reg host_rx_re;
    assign rx_full = (rx_cnt == 3'd4);
    assign rx_level = rx_cnt;
    always @(posedge clk) begin
        if (rst) begin
            rx_rd <= 0;
            rx_wr <= 0;
            rx_cnt <= 0;
        end else begin
            if (rx_push) begin
                rxf[rx_wr] <= rx_data;
                rx_wr <= rx_wr + 2'd1;
            end
            if (host_rx_re)
                rx_rd <= rx_rd + 2'd1;
            rx_cnt <= rx_cnt + {2'd0, rx_push} - {2'd0, host_rx_re};
        end
    end

    // IRQ flags, set and cleared by the SM and the host (write 1 to clear).
    reg [7:0] host_irq_clr;
    always @(posedge clk) begin
        if (rst)
            irq_flags <= 8'd0;
        else
            irq_flags <= (irq_flags & ~(irq_clr | host_irq_clr)) | irq_set;
    end

    // GPIO output level and direction registers, written by the SM.
    reg [W-1:0] gpio_out, gpio_oe;
    always @(posedge clk) begin
        if (rst) begin
            gpio_out <= '0;
            gpio_oe <= '0;
        end else begin
            gpio_out <= (gpio_out & ~pins_we) | (pins_wdata & pins_we);
            gpio_oe <= (gpio_oe & ~dirs_we) | (dirs_wdata & dirs_we);
        end
    end

    // Pad levels. Undriven pins read high (pull-up). The RX pin's external
    // level is the TX line in loopback, otherwise the testbench driver.
    reg loopback;
    reg drv_line;
    wire tx_line = gpio_oe[TXP] ? gpio_out[TXP] : 1'b1;
    wire rx_line = loopback ? tx_line : drv_line;
    reg [W-1:0] ext_in;
    always @* begin
        ext_in = '1;
        ext_in[RXP] = rx_line;
    end
    assign gpio_in = (gpio_oe & gpio_out) | (~gpio_oe & ext_in);

    // Every program instruction is non-blocking, so the SM must never stall:
    // a stall would freeze both directions.
    int stalls;
    always @(posedge clk)
        if (!rst && dut.active && dut.stall)
            stalls++;

    // Cycles where both lines are low at once: TX and RX frames overlapping.
    int both_low;
    always @(posedge clk)
        if (!rst && !loopback && tx_line === 1'b0 && drv_line === 1'b0)
            both_low++;

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_uart);
    end

`ifdef SV_TEST
    // ------------------------------------------------------------------------
    // Instruction encoders (RP2040 datasheet table 366)
    // ------------------------------------------------------------------------

    localparam [2:0] C_ALWAYS = 0, C_Y_DEC = 4, C_PIN = 6;
    localparam [2:0] IN_PINS = 0;
    localparam [2:0] O_PINS = 0;
    localparam [2:0] S_PINS = 0, S_Y = 2, S_PINDIRS = 4;
    localparam [2:0] M_X = 1;
    localparam [1:0] MOP_INV = 1;
    localparam [2:0] MS_NULL = 3;

    function automatic [15:0] i_jmp(input [2:0] cond, input [4:0] addr);
        i_jmp = {3'b000, 5'd0, cond, addr};
    endfunction
    function automatic [15:0] i_in(input [2:0] src, input [5:0] n);
        i_in = {3'b010, 5'd0, src, n[4:0]};
    endfunction
    function automatic [15:0] i_out(input [2:0] dst, input [5:0] n);
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
    // Fill in the delay field (no side-set in this program: all 5 bits delay).
    function automatic [15:0] dly(input [15:0] ins, input [4:0] d);
        dly = ins | {3'b000, d, 8'd0};
    endfunction

    // Configuration register builders (RP2040 bit layout).
    function automatic [31:0] pinctrl_f(input [2:0] sideset_count, input [2:0] set_count,
                                        input [5:0] out_count, input [4:0] in_base,
                                        input [4:0] sideset_base, input [4:0] set_base,
                                        input [4:0] out_base);
        pinctrl_f = {sideset_count, set_count, out_count, in_base, sideset_base, set_base, out_base};
    endfunction
    function automatic [31:0] execctrl_f(input side_en, input side_pindir, input [4:0] jmp_pin,
                                         input [4:0] wrap_top, input [4:0] wrap_bottom);
        execctrl_f = {1'b0, side_en, side_pindir, jmp_pin, 5'd0, 1'b0, 1'b0,
                      wrap_top, wrap_bottom, 7'd0};
    endfunction
    function automatic [31:0] shiftctrl_f(input [4:0] pull_thresh, input [4:0] push_thresh,
                                          input out_right, input in_right,
                                          input autopull, input autopush);
        shiftctrl_f = {2'd0, pull_thresh, push_thresh, out_right, in_right, autopull, autopush, 16'd0};
    endfunction

    // ------------------------------------------------------------------------
    // The full-duplex UART program. Slots are 4 cycles; P = "pull ifempty
    // noblock", O = "out pins, 1". Times in a slot: P at 0, O at 1, then the
    // RX step at 2 (and 3).
    // ------------------------------------------------------------------------

    localparam int A_PUSH = 3, A_IDLE = 4, A_BIT = 10, A_WAITHIGH = 26;
    localparam int WRAP_TOP = 28, WRAP_BOTTOM = 26;

    function automatic [15:0] prog(input int a);
        case (a)
            // Init, runs once. Drive TX high before making it an output.
            0:  prog = i_set(S_PINS, 1);                     // set pins, 1
            1:  prog = i_set(S_PINDIRS, 1);                  // set pindirs, 1
            2:  prog = i_mov(M_X, MOP_INV, MS_NULL);         // mov x, ~null   (X = idle word)
            // Good frame: push the byte (no-op at init: ISR is empty), then idle.
            3:  prog = i_push(1, 0);                         // push iffull noblock
            // Idle slot: TX, then poll RX for a start bit.
            4:  prog = i_pull(1, 0);                         // idle: pull ifempty noblock
            5:  prog = i_out(O_PINS, 1);                     //       out pins, 1
            6:  prog = dly(i_jmp(C_PIN, A_IDLE), 1);         //       jmp pin idle [1]
            // Start bit seen. One filler slot sets the bit counter.
            7:  prog = i_pull(1, 0);
            8:  prog = i_out(O_PINS, 1);
            9:  prog = dly(i_set(S_Y, 7), 1);                // set y, 7 [1]
            // Bit loop, 3 slots per bit; the bit is sampled in the third.
            10: prog = i_pull(1, 0);                         // bit: slot 1
            11: prog = dly(i_out(O_PINS, 1), 2);             //      out pins, 1 [2]
            12: prog = i_pull(1, 0);                         //      slot 2
            13: prog = dly(i_out(O_PINS, 1), 2);
            14: prog = i_pull(1, 0);                         //      slot 3
            15: prog = i_out(O_PINS, 1);
            16: prog = i_in(IN_PINS, 1);                     //      in pins, 1
            17: prog = i_jmp(C_Y_DEC, A_BIT);                //      jmp y-- bit
            // Stop bit: two slots, then check the line in the third.
            18: prog = i_pull(1, 0);
            19: prog = dly(i_out(O_PINS, 1), 2);
            20: prog = i_pull(1, 0);
            21: prog = dly(i_out(O_PINS, 1), 2);
            22: prog = i_pull(1, 0);
            23: prog = i_out(O_PINS, 1);
            24: prog = i_jmp(C_PIN, A_PUSH);                 // jmp pin push   (stop bit high)
            25: prog = i_irq(0, 0, 5'h14);                   // irq 4 rel      (framing error)
            // Wait for the line to go high again. Wrap 28 -> 26 loops here.
            26: prog = i_pull(1, 0);                         // waithigh:
            27: prog = i_out(O_PINS, 1);
            28: prog = dly(i_jmp(C_PIN, A_IDLE), 1);         // jmp pin idle [1]
            default: prog = i_jmp(C_ALWAYS, a[4:0]);
        endcase
    endfunction

    // The same program, hand-assembled.
    function automatic [15:0] prog_hex(input int a);
        case (a)
            0: prog_hex = 16'hE001;  1: prog_hex = 16'hE081;  2: prog_hex = 16'hA02B;
            3: prog_hex = 16'h8040;  4: prog_hex = 16'h80C0;  5: prog_hex = 16'h6001;
            6: prog_hex = 16'h01C4;  7: prog_hex = 16'h80C0;  8: prog_hex = 16'h6001;
            9: prog_hex = 16'hE147; 10: prog_hex = 16'h80C0; 11: prog_hex = 16'h6201;
           12: prog_hex = 16'h80C0; 13: prog_hex = 16'h6201; 14: prog_hex = 16'h80C0;
           15: prog_hex = 16'h6001; 16: prog_hex = 16'h4001; 17: prog_hex = 16'h008A;
           18: prog_hex = 16'h80C0; 19: prog_hex = 16'h6201; 20: prog_hex = 16'h80C0;
           21: prog_hex = 16'h6201; 22: prog_hex = 16'h80C0; 23: prog_hex = 16'h6001;
           24: prog_hex = 16'h00C3; 25: prog_hex = 16'hC014; 26: prog_hex = 16'h80C0;
           27: prog_hex = 16'h6001; 28: prog_hex = 16'h01C4;
           default: prog_hex = i_jmp(C_ALWAYS, a[4:0]);
        endcase
    endfunction

    // Host side of TX: start bit, data LSB first, stop bit, each bit 3 times,
    // plus two 1s of padding. Sent to the FIFO as 4 bytes, low byte first.
    function automatic [31:0] frame_word(input [7:0] data);
        reg [9:0] f;
        f = {1'b1, data, 1'b0};
        frame_word = '1;                                 // bits 31:30: padding
        for (int i = 0; i < 10; i++)
            frame_word[3 * i +: 3] = {3{f[i]}};
    endfunction

    // ------------------------------------------------------------------------
    // Helpers. Inputs change and checks happen 1 ns after the rising edge;
    // inputs must not change near the falling edge (scratch register writes).
    // ------------------------------------------------------------------------

    initial clk = 0;
    always #5 clk = ~clk;

    task automatic step(input int n);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check(input [31:0] got, input [31:0] exp, input string what);
        if (got !== exp)
            $fatal(1, "%s: got %h, expected %h", what, got, exp);
    endtask

    // Reset, load the program and config, and boot. div is the clock divisor
    // as 16.8 fixed point ({int, frac}). The SM is left disabled.
    task automatic reset_all(input [23:0] div);
        rst = 1;
        en = 0;
        host_tx_we = 0;
        host_tx_wdata = 0;
        host_rx_re = 0;
        host_irq_clr = 0;
        loopback = 1;
        drv_line = 1;
        pinctrl   = pinctrl_f(0, 1, 1, RXP, 0, TXP, TXP);   // SET, OUT on TXP; IN_BASE = RXP
        execctrl  = execctrl_f(0, 0, RXP, WRAP_TOP, WRAP_BOTTOM);
        shiftctrl = shiftctrl_f(8, 8, 1, 1, 0, 0);           // 8 TX bits per word, 8 RX bits
        clkdiv    = {div, 8'd0};
        // Program at 0-31, config at 32-39 (CLKDIV, EXECCTRL, SHIFTCTRL,
        // PINCTRL; low half first). The SM loads its config at boot.
        for (int i = 0; i < 32; i++)
            imem[i] = prog(i);
        {imem[33], imem[32]} = clkdiv;
        {imem[35], imem[34]} = execctrl;
        {imem[37], imem[36]} = shiftctrl;
        {imem[39], imem[38]} = pinctrl;
        step(2);
        rst = 0;
        step(8);                        // boot: load addresses 32-39
        stalls = 0;
        both_low = 0;
    endtask

    // Host sends a byte: waits until the TX FIFO is empty, then writes the
    // 4 bytes of its frame word on 4 consecutive cycles, low byte first.
    // Writing all 4 together means the SM never runs out mid-frame.
    task automatic tx_put(input [7:0] b);
        int guard;
        reg [31:0] fw;
        guard = 0;
        while (tx_cnt != 3'd0) begin
            step(1);
            if (++guard > 20000)
                $fatal(1, "TX FIFO never drained");
        end
        fw = frame_word(b);
        for (int k = 0; k < 4; k++) begin
            host_tx_we = 1;
            host_tx_wdata = fw[8 * k +: 8];
            step(1);
        end
        host_tx_we = 0;
    endtask

    // Host reads a byte from the RX FIFO, waiting up to max_cycles for one.
    task automatic rx_get(output [7:0] b, input int max_cycles);
        int guard;
        guard = 0;
        while (rx_cnt == 3'd0) begin
            step(1);
            if (++guard > max_cycles)
                $fatal(1, "RX FIFO: no byte within %0d cycles", max_cycles);
        end
        b = rxf[rx_rd];
        host_rx_re = 1;
        step(1);
        host_rx_re = 0;
    endtask

    // Watch one UART frame on the TX line: start bit, 8 data bits LSB
    // first, stop bit, each exactly bit_cycles long. Returns the byte and
    // how many idle-high cycles came before the start bit. Returns at the
    // last cycle of the stop bit.
    task automatic uart_frame(input int bit_cycles, output [7:0] data, output int idle);
        reg [9:0] frame;
        idle = 0;
        while (tx_line !== 1'b0) begin
            step(1);
            if (++idle > 20000)
                $fatal(1, "UART TX: no start bit");
        end
        for (int b = 0; b < 10; b++) begin
            frame[b] = tx_line;
            for (int c = 0; c < bit_cycles; c++) begin
                if (tx_line !== frame[b])
                    $fatal(1, "UART TX: bit %0d changed after %0d of %0d cycles", b, c, bit_cycles);
                if (b < 9 || c < bit_cycles - 1)
                    step(1);
            end
        end
        if (frame[0] !== 1'b0 || frame[9] !== 1'b1)
            $fatal(1, "UART TX: bad start/stop bits %b", frame);
        data = frame[8:1];
    endtask

    // The external device sends one frame on the RX line. stop = 0 makes a
    // bad stop bit. The line stays at the stop level afterwards.
    task automatic drive_frame(input [7:0] data, input int bit_cycles, input stop);
        reg [9:0] f;
        f = {stop, data, 1'b0};
        for (int b = 0; b < 10; b++) begin
            drv_line = f[b];
            step(bit_cycles);
        end
    endtask

    // Program counter regions.
    function automatic bit in_idle(input [5:0] p);
        in_idle = (p >= A_IDLE && p <= A_IDLE + 2);
    endfunction
    function automatic bit in_waithigh(input [5:0] p);
        in_waithigh = (p >= A_WAITHIGH && p <= WRAP_TOP);
    endfunction

    reg [7:0] pattern [0:7];
    reg [7:0] other [0:7];
    initial begin
        pattern[0] = 8'h55; pattern[1] = 8'h00; pattern[2] = 8'hFF; pattern[3] = 8'h01;
        pattern[4] = 8'h80; pattern[5] = 8'hA5; pattern[6] = 8'h3C; pattern[7] = 8'hC3;
        other[0] = 8'h96; other[1] = 8'h69; other[2] = 8'hF0; other[3] = 8'h0F;
        other[4] = 8'h7E; other[5] = 8'h81; other[6] = 8'h33; other[7] = 8'hCC;
    end

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    // 1. The encoders build the hand-assembled program.
    task automatic test_program();
        for (int a = 0; a < 32; a++)
            check(prog(a), prog_hex(a), $sformatf("program word %0d", a));
        // 0x96 framed LSB first: start 0, data 0 1 1 0 1 0 0 1, stop 1.
        // Read from bit 31 down: unused 11, then stop, d7 ... d0, start.
        check(frame_word(8'h96), 32'b11_111_111_000_000_111_000_111_111_000_000,
              "frame_word(0x96)");
    endtask

    // 2. TX with the RX line idle: pin directions, idle level, exact bit
    //    timing, data, and back-to-back frames.
    task automatic test_tx(input int div);
        reg [7:0] b;
        int idle;
        reset_all(div[15:0] << 8);
        loopback = 0;
        en = 1;
        step(2 * div);                       // set pins, set pindirs
        check(gpio_oe, 32'h1 << TXP, $sformatf("tx div %0d: only TXP is an output", div));
        check(tx_line, 1, $sformatf("tx div %0d: idle high", div));
        step(40 * div);
        check(tx_line, 1, $sformatf("tx div %0d: still idle", div));
        // tx_put waits for an empty FIFO, so the host runs alongside the watcher.
        fork
            for (int i = 0; i < 8; i++)
                tx_put(pattern[i]);
            for (int i = 0; i < 8; i++) begin
                uart_frame(BIT * div, b, idle);
                check(b, pattern[i], $sformatf("tx div %0d: byte %0d", div, i));
                if (i > 0)       // only the 2 padding slots between frames
                    check(idle, 1 + PAD * div, $sformatf("tx div %0d: back-to-back gap", div));
            end
        join
        step(30 * div);
        check(tx_line, 1, $sformatf("tx div %0d: idle after frames", div));
        check(rx_cnt, 0, $sformatf("tx div %0d: nothing received", div));
        check(irq_flags, 0, $sformatf("tx div %0d: no framing error", div));
        check(gpio_oe, 32'h1 << TXP, $sformatf("tx div %0d: directions unchanged", div));
        check(stalls, 0, $sformatf("tx div %0d: never stalls", div));
    endtask

    // 3. RX from the external device, with the frame starting at every
    //    possible cycle offset relative to the SM's slots.
    task automatic test_rx_phases(input int div);
        reg [7:0] b;
        int bc;
        bc = BIT * div;
        reset_all(div[15:0] << 8);
        loopback = 0;
        en = 1;
        step(5);
        for (int off = 0; off < bc; off++) begin
            step(off);
            drive_frame(other[off % 8], bc, 1);
            rx_get(b, 4 * bc);
            check(b, other[off % 8], $sformatf("rx div %0d: offset %0d", div, off));
        end
        step(2 * bc);
        check(rx_cnt, 0, $sformatf("rx div %0d: no extra bytes", div));
        check(irq_flags, 0, $sformatf("rx div %0d: no framing error", div));
        check(tx_line, 1, $sformatf("rx div %0d: TX stays idle", div));
        check(stalls, 0, $sformatf("rx div %0d: never stalls", div));
    endtask

    // 4. Full duplex: the host sends 8 bytes while the external device sends
    //    8 different bytes, at the same time and with unrelated timing.
    task automatic test_full_duplex(input int div);
        int bc;
        bc = BIT * div;
        reset_all(div[15:0] << 8);
        loopback = 0;
        en = 1;
        step(5);
        fork
            begin : host_tx
                for (int i = 0; i < 8; i++)
                    tx_put(pattern[i]);
            end
            begin : watch_tx
                reg [7:0] b;
                int idle;
                for (int i = 0; i < 8; i++) begin
                    uart_frame(bc, b, idle);
                    check(b, pattern[i], $sformatf("duplex div %0d: TX byte %0d", div, i));
                end
            end
            begin : device_tx
                reg [7:0] b;
                step(7);                            // start mid-slot, mid-TX-bit
                for (int i = 0; i < 8; i++) begin
                    drive_frame(other[i], bc, 1);
                    step(i);                        // vary the phase frame to frame
                end
            end
            begin : host_rx
                reg [7:0] b;
                for (int i = 0; i < 8; i++) begin
                    rx_get(b, 20 * bc);
                    check(b, other[i], $sformatf("duplex div %0d: RX byte %0d", div, i));
                end
            end
        join
        check(both_low > 10 * bc, 1, $sformatf("duplex div %0d: frames overlapped", div));
        check(irq_flags, 0, $sformatf("duplex div %0d: no framing error", div));
        check(stalls, 0, $sformatf("duplex div %0d: never stalls", div));
    endtask

    // 5. Loopback TX -> RX on the same SM, including a fractional divisor.
    task automatic test_loopback(input [23:0] div, input string name);
        reg [7:0] b;
        reset_all(div);
        en = 1;
        for (int g = 0; g < 2; g++) begin
            for (int i = 0; i < 4; i++)
                tx_put(pattern[4 * g + i]);
            for (int i = 0; i < 4; i++) begin
                rx_get(b, 1000 * (div >> 8) + 1000);
                check(b, pattern[4 * g + i], $sformatf("loopback %s: byte %0d", name, 4 * g + i));
            end
        end
        step(40 * (div >> 8) + 40);
        check(rx_cnt, 0, $sformatf("loopback %s: no extra bytes", name));
        check(irq_flags, 0, $sformatf("loopback %s: no framing error", name));
        check(in_idle(pc), 1, $sformatf("loopback %s: RX back to idle", name));
        check(stalls, 0, $sformatf("loopback %s: never stalls", name));
    endtask

    // 6. Framing error: a low stop bit sets IRQ flag 4 rel, pushes nothing,
    //    and RX waits for the line to go high. TX keeps working meanwhile.
    task automatic test_rx_framing(input int div);
        reg [7:0] b;
        int bc, idle;
        bc = BIT * div;
        reset_all(div[15:0] << 8);
        loopback = 0;
        en = 1;
        step(5);
        drive_frame(8'h96, bc, 1);
        rx_get(b, 4 * bc);
        check(b, 8'h96, $sformatf("framing div %0d: good byte", div));

        drive_frame(8'h00, bc, 0);           // break: stop bit low, line held low
        step(2 * bc);
        check(rx_cnt, 0, $sformatf("framing div %0d: bad frame not pushed", div));
        check(irq_flags, 8'h1 << ERR_FLAG, $sformatf("framing div %0d: error flag", div));
        check(in_waithigh(pc), 1, $sformatf("framing div %0d: waiting for line high", div));
        tx_put(8'hA5);                       // TX still runs during the break
        uart_frame(bc, b, idle);
        check(b, 8'hA5, $sformatf("framing div %0d: TX during break", div));
        check(in_waithigh(pc), 1, $sformatf("framing div %0d: still waiting", div));
        check(rx_cnt, 0, $sformatf("framing div %0d: nothing pushed during break", div));

        drv_line = 1;
        step(bc);
        check(in_idle(pc), 1, $sformatf("framing div %0d: recovered", div));
        host_irq_clr = 8'h1 << ERR_FLAG;
        step(1);
        host_irq_clr = 0;
        step(1);
        check(irq_flags, 0, $sformatf("framing div %0d: host cleared the flag", div));

        drive_frame(8'h69, bc, 1);
        rx_get(b, 4 * bc);
        check(b, 8'h69, $sformatf("framing div %0d: byte after error", div));
        check(irq_flags, 0, $sformatf("framing div %0d: no new error", div));
        check(stalls, 0, $sformatf("framing div %0d: never stalls", div));
    endtask

    // 7. RX FIFO full: PUSH is non-blocking, so with nobody reading, bytes
    //    1-4 are kept, later ones are dropped, and TX never stops.
    task automatic test_rx_fifo_full();
        reg [7:0] b;
        int idle;
        reset_all(24'h0100);
        en = 1;
        for (int i = 0; i < 6; i++)
            tx_put(pattern[i]);
        step(6 * 10 * BIT + 40 * BIT);
        check(rx_cnt, 4, "rx full: FIFO holds 4");
        check(tx_cnt, 0, "rx full: TX sent everything");
        check(stalls, 0, "rx full: never stalls");
        for (int i = 0; i < 4; i++) begin
            rx_get(b, 20);
            check(b, pattern[i], $sformatf("rx full: byte %0d", i));
        end
        check(rx_cnt, 0, "rx full: bytes 5 and 6 were dropped");
        tx_put(8'h3C);
        rx_get(b, 40 * BIT);
        check(b, 8'h3C, "rx full: receives again after reading");
    endtask

    initial begin
        test_program();
        test_tx(1);
        test_tx(3);
        test_rx_phases(1);
        test_rx_phases(3);
        test_full_duplex(1);
        test_full_duplex(3);
        test_loopback(24'h0100, "div 1");
        test_loopback(24'h0300, "div 3");
        test_loopback(24'h0280, "div 2.5");
        test_rx_framing(1);
        test_rx_framing(2);
        test_rx_fifo_full();

        $display("SM UART SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
