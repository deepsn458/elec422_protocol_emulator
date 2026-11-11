`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_uart.fst"
`endif

// UART test for sm_no_smx_instr with DATA_WIDTH = 8.
//
// Two state machines share 8 GPIOs:
//   * tx_sm (SM 0) runs uart_tx from the RP2040 datasheet and drives GPIO TXP.
//   * rx_sm (SM 1) runs uart_rx (with framing-error IRQ) and reads GPIO RXP.
// The RX pin is either looped back from the TX pin or driven by the
// testbench. Pins that nothing drives read high (UART idle, as with a
// pull-up).
//
// There is no SMx_INSTR, so nothing can set the PC or the pin directions
// from outside. Each SM therefore has its own instruction memory (both
// programs start at address 0), and uart_tx sets its own pin direction
// with an extra first instruction that the wrap skips.

module tb_sm_uart;
    localparam int W = 8;               // DATA_WIDTH: X, Y, ISR, OSR, FIFO words, GPIOs
    localparam int TXP = 6;             // TX pin
    localparam int RXP = 2;             // RX pin
    localparam [1:0] TX_ID = 2'd0;
    localparam [1:0] RX_ID = 2'd1;      // irq 4 rel on SM 1 sets flag 5
    localparam int ERR_FLAG = 4 + RX_ID;

    reg clk;
    reg rst;
    reg en_tx, en_rx;
    reg [31:0] clkdiv;                  // shared, so both SMs tick together
    reg [31:0] tx_execctrl, tx_shiftctrl, tx_pinctrl;
    reg [31:0] rx_execctrl, rx_shiftctrl, rx_pinctrl;

    // tx_sm
    wire [4:0] tx_pc;
    wire tx_read_en;
    wire [W-1:0] tx_data;
    wire tx_empty;
    wire [2:0] tx_level;
    wire tx_pop;
    wire [W-1:0] tx_rx_data;
    wire tx_rx_push;
    wire [W-1:0] tx_pins_we, tx_pins_wdata, tx_dirs_we, tx_dirs_wdata;
    wire [7:0] tx_irq_set, tx_irq_clr;

    // rx_sm
    wire [4:0] rx_pc;
    wire rx_read_en;
    wire rx_tx_pop;
    wire [W-1:0] rx_data;
    wire rx_full;
    wire [2:0] rx_level;
    wire rx_push;
    wire [W-1:0] rx_pins_we, rx_pins_wdata, rx_dirs_we, rx_dirs_wdata;
    wire [7:0] rx_irq_set, rx_irq_clr;

    wire [W-1:0] gpio_in;
    reg [7:0] irq_flags;

    // Instruction memories, combinational read.
    reg [15:0] tx_imem [0:31];
    reg [15:0] rx_imem [0:31];

    sm_no_smx_instr #(.SM_ID(TX_ID), .DATA_WIDTH(W)) tx_sm (
        .clk(clk),
        .rst(rst),
        .en(en_tx),
        .restart(1'b0),
        .clkdiv_restart(1'b0),
        .clkdiv(clkdiv),
        .execctrl(tx_execctrl),
        .shiftctrl(tx_shiftctrl),
        .pinctrl(tx_pinctrl),
        .mem_addr(tx_pc),
        .read_en(tx_read_en),
        .instr(tx_imem[tx_pc]),
        .tx_data(tx_data),
        .tx_empty(tx_empty),
        .tx_level(tx_level),
        .tx_pop(tx_pop),
        .rx_data(tx_rx_data),
        .rx_full(1'b0),
        .rx_level(3'd0),
        .rx_push(tx_rx_push),
        .gpio_in(gpio_in),
        .pins_we(tx_pins_we),
        .pins_wdata(tx_pins_wdata),
        .dirs_we(tx_dirs_we),
        .dirs_wdata(tx_dirs_wdata),
        .irq_flags(irq_flags),
        .irq_set(tx_irq_set),
        .irq_clr(tx_irq_clr)
    );

    sm_no_smx_instr #(.SM_ID(RX_ID), .DATA_WIDTH(W)) rx_sm (
        .clk(clk),
        .rst(rst),
        .en(en_rx),
        .restart(1'b0),
        .clkdiv_restart(1'b0),
        .clkdiv(clkdiv),
        .execctrl(rx_execctrl),
        .shiftctrl(rx_shiftctrl),
        .pinctrl(rx_pinctrl),
        .mem_addr(rx_pc),
        .read_en(rx_read_en),
        .instr(rx_imem[rx_pc]),
        .tx_data('0),
        .tx_empty(1'b1),
        .tx_level(3'd0),
        .tx_pop(rx_tx_pop),
        .rx_data(rx_data),
        .rx_full(rx_full),
        .rx_level(rx_level),
        .rx_push(rx_push),
        .gpio_in(gpio_in),
        .pins_we(rx_pins_we),
        .pins_wdata(rx_pins_wdata),
        .dirs_we(rx_dirs_we),
        .dirs_wdata(rx_dirs_wdata),
        .irq_flags(irq_flags),
        .irq_set(rx_irq_set),
        .irq_clr(rx_irq_clr)
    );

    // ------------------------------------------------------------------------
    // Models of the blocks around the state machines
    // ------------------------------------------------------------------------

    // 4-deep first-word fall-through TX FIFO for tx_sm, written by the host.
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

    // 4-deep RX FIFO for rx_sm, read by the host.
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

    // IRQ flags, set and cleared by both SMs and the host (write 1 to clear).
    reg [7:0] host_irq_clr;
    always @(posedge clk) begin
        if (rst)
            irq_flags <= 8'd0;
        else
            irq_flags <= (irq_flags & ~(tx_irq_clr | rx_irq_clr | host_irq_clr))
                       | tx_irq_set | rx_irq_set;
    end

    // GPIO output level and direction registers, written by both SMs.
    reg [W-1:0] gpio_out, gpio_oe;
    always @(posedge clk) begin
        if (rst) begin
            gpio_out <= '0;
            gpio_oe <= '0;
        end else begin
            gpio_out <= (gpio_out & ~(tx_pins_we | rx_pins_we))
                      | (tx_pins_wdata & tx_pins_we) | (rx_pins_wdata & rx_pins_we);
            gpio_oe <= (gpio_oe & ~(tx_dirs_we | rx_dirs_we))
                     | (tx_dirs_wdata & tx_dirs_we) | (rx_dirs_wdata & rx_dirs_we);
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

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_uart);
    end

`ifdef SV_TEST
    // ------------------------------------------------------------------------
    // Instruction encoders (RP2040 datasheet table 366)
    // ------------------------------------------------------------------------

    localparam [2:0] C_ALWAYS = 0, C_X_DEC = 2, C_PIN = 6;
    localparam [1:0] W_PIN = 1;
    localparam [2:0] IN_PINS = 0;
    localparam [2:0] O_PINS = 0;
    localparam [2:0] S_X = 1, S_PINDIRS = 4;

    function automatic [15:0] i_jmp(input [2:0] cond, input [4:0] addr);
        i_jmp = {3'b000, 5'd0, cond, addr};
    endfunction
    function automatic [15:0] i_wait(input pol, input [1:0] src, input [4:0] idx);
        i_wait = {3'b001, 5'd0, pol, src, idx};
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

    // uart_tx, with "set pindirs, 1" in front. Side-set is 1 bit, optional
    // (SIDESET_COUNT = 2 with SIDE_EN), so "side 1" is field 5'b11xxx.
    function automatic [15:0] tx_prog(input int a);
        case (a)
            0: tx_prog = dss(i_set(S_PINDIRS, 1), 5'b11000);  // set pindirs, 1 side 1
            1: tx_prog = dss(i_pull(0, 1), 5'b11111);         // pull side 1 [7]
            2: tx_prog = dss(i_set(S_X, 7), 5'b10111);        // set x, 7 side 0 [7]
            3: tx_prog = i_out(O_PINS, 1);                    // out pins, 1
            4: tx_prog = dss(i_jmp(C_X_DEC, 3), 5'b00110);    // jmp x-- 3 [6]
            default: tx_prog = i_jmp(C_ALWAYS, a[4:0]);
        endcase
    endfunction
    localparam int TX_WRAP_TOP = 4, TX_WRAP_BOTTOM = 1, TX_PULL = 1;

    // uart_rx from the datasheet (with framing-error IRQ). No side-set.
    function automatic [15:0] rx_prog(input int a);
        case (a)
            0: rx_prog = i_wait(0, W_PIN, 0);                 // start: wait 0 pin 0
            1: rx_prog = dss(i_set(S_X, 7), 5'd10);           // set x, 7 [10]
            2: rx_prog = i_in(IN_PINS, 1);                    // bitloop: in pins, 1
            3: rx_prog = dss(i_jmp(C_X_DEC, 2), 5'd6);        // jmp x-- bitloop [6]
            4: rx_prog = i_jmp(C_PIN, 8);                     // jmp pin good_stop
            5: rx_prog = i_irq(0, 0, 5'h14);                  // irq 4 rel
            6: rx_prog = i_wait(1, W_PIN, 0);                 // wait 1 pin 0
            7: rx_prog = i_jmp(C_ALWAYS, 0);                  // jmp start
            8: rx_prog = i_push(0, 1);                        // good_stop: push
            default: rx_prog = i_jmp(C_ALWAYS, a[4:0]);
        endcase
    endfunction
    localparam int RX_WRAP_TOP = 8, RX_WRAP_BOTTOM = 0, RX_START = 0, RX_PUSH = 8;

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

    // Reset both SMs and load both programs. div is the clock divisor as
    // 16.8 fixed point ({int, frac}); each UART bit is 8 SM cycles.
    task automatic reset_all(input [23:0] div);
        rst = 1;
        en_tx = 0;
        en_rx = 0;
        host_tx_we = 0;
        host_tx_wdata = 0;
        host_rx_re = 0;
        host_irq_clr = 0;
        loopback = 1;
        drv_line = 1;
        for (int i = 0; i < 32; i++) begin
            tx_imem[i] = tx_prog(i);
            rx_imem[i] = rx_prog(i);
        end
        tx_pinctrl   = pinctrl_f(2, 1, 1, 0, TXP, TXP, TXP);   // side-set, SET, OUT on TXP
        tx_execctrl  = execctrl_f(1, 0, 0, TX_WRAP_TOP, TX_WRAP_BOTTOM);
        tx_shiftctrl = shiftctrl_f(0, 0, 1, 1, 0, 0);          // OUT shifts right (LSB first)
        rx_pinctrl   = pinctrl_f(0, 0, 0, RXP, 0, 0, 0);       // IN_BASE = RXP
        rx_execctrl  = execctrl_f(0, 0, RXP, RX_WRAP_TOP, RX_WRAP_BOTTOM);
        rx_shiftctrl = shiftctrl_f(0, 0, 1, 1, 0, 0);          // IN shifts right
        clkdiv = {div, 8'd0};
        step(2);
        rst = 0;
    endtask

    task automatic start();
        en_tx = 1;
        en_rx = 1;
    endtask

    // Host writes a byte to the TX FIFO, waiting while it is full.
    task automatic tx_put(input [W-1:0] b);
        int guard;
        guard = 0;
        while (tx_cnt == 3'd4) begin
            step(1);
            if (++guard > 10000)
                $fatal(1, "TX FIFO never drained");
        end
        host_tx_we = 1;
        host_tx_wdata = b;
        step(1);
        host_tx_we = 0;
    endtask

    // Host reads a byte from the RX FIFO, waiting up to max_cycles for one.
    task automatic rx_get(output [W-1:0] b, input int max_cycles);
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
            if (++idle > 5000)
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

    // Drive one UART frame on the RX pin from the testbench. The line stays
    // at the stop-bit level afterwards (low for a bad stop bit / break).
    task automatic drive_frame(input [7:0] data, input int bit_cycles, input stop);
        reg [9:0] frame;
        frame = {stop, data, 1'b0};
        for (int b = 0; b < 10; b++) begin
            drv_line = frame[b];
            step(bit_cycles);
        end
    endtask

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    reg [7:0] pattern [0:7];
    initial begin
        pattern[0] = 8'h55; pattern[1] = 8'h00; pattern[2] = 8'hFF; pattern[3] = 8'h01;
        pattern[4] = 8'h80; pattern[5] = 8'hA5; pattern[6] = 8'h3C; pattern[7] = 8'hC3;
    end

    // 1. The programs match pioasm output (uart_tx.pio / uart_rx.pio).
    task automatic test_encoders();
        check(tx_prog(1), 16'h9FA0, "uart_tx: pull side 1 [7]");
        check(tx_prog(2), 16'hF727, "uart_tx: set x, 7 side 0 [7]");
        check(tx_prog(3), 16'h6001, "uart_tx: out pins, 1");
        check(rx_prog(0), 16'h2020, "uart_rx: wait 0 pin 0");
        check(rx_prog(1), 16'hEA27, "uart_rx: set x, 7 [10]");
        check(rx_prog(2), 16'h4001, "uart_rx: in pins, 1");
        check(rx_prog(3), 16'h0642, "uart_rx: jmp x-- 2 [6]");
        check(rx_prog(4), 16'h00C8, "uart_rx: jmp pin 8");
        check(rx_prog(5), 16'hC014, "uart_rx: irq 4 rel");
        check(rx_prog(6), 16'h20A0, "uart_rx: wait 1 pin 0");
        check(rx_prog(7), 16'h0000, "uart_rx: jmp 0");
        check(rx_prog(8), 16'h8020, "uart_rx: push");
    endtask

    // 2. TX: frame timing and data at integer divisors. Idle is high, the
    // SM only touches its own pin, back-to-back bytes have exactly one stop
    // bit between them, and the SM waits on PULL when the FIFO is empty.
    task automatic test_tx(input int div);
        reg [7:0] b;
        int idle;
        reset_all(div[15:0] << 8);
        en_tx = 1;
        step(1);
        check(gpio_oe, 8'h1 << TXP, $sformatf("tx div %0d: only TXP is an output", div));
        check(tx_line, 1, $sformatf("tx div %0d: idle high", div));
        step(20 * div);
        check(tx_line, 1, $sformatf("tx div %0d: still idle", div));
        check(tx_pc, TX_PULL, $sformatf("tx div %0d: waiting on PULL", div));
        for (int g = 0; g < 2; g++) begin
            for (int i = 0; i < 4; i++)
                tx_put(pattern[4 * g + i]);
            for (int i = 0; i < 4; i++) begin
                uart_frame(8 * div, b, idle);
                check(b, pattern[4 * g + i], $sformatf("tx div %0d: byte %0d", div, 4 * g + i));
                if (i > 0)
                    check(idle, 1, $sformatf("tx div %0d: back-to-back gap", div));
            end
        end
        step(30 * div);
        check(tx_line, 1, $sformatf("tx div %0d: idle after frames", div));
        check(tx_pc, TX_PULL, $sformatf("tx div %0d: back on PULL", div));
        check(gpio_oe, 8'h1 << TXP, $sformatf("tx div %0d: directions unchanged", div));
    endtask

    // 3. Loopback TX -> RX: every byte sent comes back through the RX FIFO,
    // with no framing error. Includes a fractional divisor (2.5), where bit
    // lengths alternate between 20 and 21 cycles... the RX samples mid-bit
    // and must still get every byte.
    task automatic test_loopback(input [23:0] div, input string name);
        reg [7:0] b;
        reset_all(div);
        start();
        for (int g = 0; g < 2; g++) begin
            for (int i = 0; i < 4; i++)
                tx_put(pattern[4 * g + i]);
            for (int i = 0; i < 4; i++) begin
                rx_get(b, 400 * (div >> 8) + 400);
                check(b, pattern[4 * g + i], $sformatf("loopback %s: byte %0d", name, 4 * g + i));
            end
        end
        step(40);
        check(rx_cnt, 0, $sformatf("loopback %s: no extra bytes", name));
        check(irq_flags, 0, $sformatf("loopback %s: no framing error", name));
        check(rx_pc, RX_START, $sformatf("loopback %s: RX waiting for start bit", name));
    endtask

    // 4. RX from an external driver, and the framing-error path: a frame with
    // a low stop bit raises IRQ flag 4 rel (flag 5 on SM 1) and pushes
    // nothing; RX recovers once the line goes high, and the host clears the
    // flag by writing 1.
    task automatic test_rx_framing(input int div);
        reg [7:0] b;
        int bc;
        bc = 8 * div;
        reset_all(div[15:0] << 8);
        loopback = 0;
        en_rx = 1;
        step(5);
        drive_frame(8'h96, bc, 1);
        rx_get(b, 4 * bc);
        check(b, 8'h96, $sformatf("rx div %0d: driven byte", div));

        drive_frame(8'h00, bc, 0);           // break: stop bit low
        step(2 * bc);
        check(rx_cnt, 0, $sformatf("rx div %0d: bad frame not pushed", div));
        check(irq_flags, 8'h1 << ERR_FLAG, $sformatf("rx div %0d: framing error flag", div));
        check(rx_pc, 6, $sformatf("rx div %0d: waiting for line high", div));
        drv_line = 1;
        step(bc);
        check(rx_pc, RX_START, $sformatf("rx div %0d: recovered", div));
        host_irq_clr = 8'h1 << ERR_FLAG;
        step(1);
        host_irq_clr = 0;
        step(1);
        check(irq_flags, 0, $sformatf("rx div %0d: host cleared the flag", div));

        drive_frame(8'h69, bc, 1);
        rx_get(b, 4 * bc);
        check(b, 8'h69, $sformatf("rx div %0d: byte after error", div));
        check(irq_flags, 0, $sformatf("rx div %0d: no new error", div));
    endtask

    // 5. RX FIFO full: with nobody reading, four bytes fill the FIFO and the
    // fifth stalls on PUSH. Reading one byte lets it through.
    task automatic test_rx_fifo_full();
        reg [7:0] b;
        reset_all(24'h0100);
        start();
        for (int i = 0; i < 4; i++)
            tx_put(pattern[i]);
        tx_put(pattern[4]);
        step(5 * 10 * 8 + 40);
        check(rx_cnt, 4, "rx full: FIFO holds 4");
        check(rx_pc, RX_PUSH, "rx full: stalled on PUSH");
        for (int i = 0; i < 5; i++) begin
            rx_get(b, 20);
            check(b, pattern[i], $sformatf("rx full: byte %0d", i));
        end
    endtask

    initial begin
        test_encoders();
        test_tx(1);
        test_tx(3);
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
