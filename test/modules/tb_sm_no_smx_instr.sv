`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_sm_no_smx_instr.fst"
`endif

module tb_sm_no_smx_instr;
    // SM_ID = 1 so that relative IRQ indices differ from absolute ones.
    localparam [1:0] SM_ID = 2'd1;
    // Data path / GPIO width. The test values below assume 16.
    localparam int W = 16;

    reg clk;
    reg rst;
    reg en;
    reg restart;
    reg clkdiv_restart;
    reg [31:0] clkdiv;
    reg [31:0] execctrl;
    reg [31:0] shiftctrl;
    reg [31:0] pinctrl;

    wire [4:0] pc;
    wire [15:0] instr;
    wire read_en;
    wire [W-1:0] tx_data;
    wire tx_empty;
    wire [2:0] tx_level;
    wire tx_pop;
    wire [W-1:0] rx_data;
    wire rx_full;
    wire [2:0] rx_level;
    wire rx_push;
    wire [W-1:0] gpio_in;
    wire [W-1:0] pins_we;
    wire [W-1:0] pins_wdata;
    wire [W-1:0] dirs_we;
    wire [W-1:0] dirs_wdata;
    reg [7:0] irq_flags;
    wire [7:0] irq_set;
    wire [7:0] irq_clr;

    sm_no_smx_instr #(.SM_ID(SM_ID), .DATA_WIDTH(W)) dut (
        .clk(clk),
        .rst(rst),
        .en(en),
        .restart(restart),
        .clkdiv_restart(clkdiv_restart),
        .clkdiv(clkdiv),
        .execctrl(execctrl),
        .shiftctrl(shiftctrl),
        .pinctrl(pinctrl),
        .mem_addr(pc),
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

    // Instruction memory, combinational read.
    reg [15:0] imem [0:31];
    assign instr = imem[pc];

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

    // IRQ flags, set and cleared by the SM and the host.
    reg [7:0] host_irq_set, host_irq_clr;
    always @(posedge clk) begin
        if (rst)
            irq_flags <= 8'd0;
        else
            irq_flags <= (irq_flags & ~(irq_clr | host_irq_clr)) | irq_set | host_irq_set;
    end

    // GPIO output level and direction registers. Pins driven by the SM read
    // back their own level; other pins read the external value ext_in.
    reg [W-1:0] gpio_out, gpio_oe, ext_in;
    always @(posedge clk) begin
        if (rst) begin
            gpio_out <= '0;
            gpio_oe <= '0;
        end else begin
            gpio_out <= (gpio_out & ~pins_we) | (pins_wdata & pins_we);
            gpio_oe <= (gpio_oe & ~dirs_we) | (dirs_wdata & dirs_we);
        end
    end
    assign gpio_in = (gpio_oe & gpio_out) | (~gpio_oe & ext_in);

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_sm_no_smx_instr);
    end

`ifdef SV_TEST
    // ------------------------------------------------------------------------
    // Instruction encoders (RP2040 datasheet table 366)
    // ------------------------------------------------------------------------

    // JMP conditions
    localparam [2:0] C_ALWAYS = 0, C_NOT_X = 1, C_X_DEC = 2, C_NOT_Y = 3,
                     C_Y_DEC = 4, C_X_NE_Y = 5, C_PIN = 6, C_NOT_OSRE = 7;
    // WAIT sources
    localparam [1:0] W_GPIO = 0, W_PIN = 1, W_IRQ = 2;
    // IN sources
    localparam [2:0] IN_PINS = 0, IN_X = 1, IN_Y = 2, IN_NULL = 3, IN_ISR = 6, IN_OSR = 7;
    // OUT destinations
    localparam [2:0] O_PINS = 0, O_X = 1, O_Y = 2, O_NULL = 3, O_PINDIRS = 4,
                     O_PC = 5, O_ISR = 6, O_EXEC = 7;
    // MOV destinations, operations and sources
    localparam [2:0] MD_PINS = 0, MD_X = 1, MD_Y = 2, MD_EXEC = 4, MD_PC = 5,
                     MD_ISR = 6, MD_OSR = 7;
    localparam [1:0] MOP_NONE = 0, MOP_INV = 1, MOP_REV = 2;
    localparam [2:0] MS_PINS = 0, MS_X = 1, MS_Y = 2, MS_NULL = 3, MS_STATUS = 5,
                     MS_ISR = 6, MS_OSR = 7;
    // SET destinations
    localparam [2:0] S_PINS = 0, S_X = 1, S_Y = 2, S_PINDIRS = 4;

    function automatic [15:0] i_jmp(input [2:0] cond, input [4:0] addr);
        i_jmp = {3'b000, 5'd0, cond, addr};
    endfunction
    function automatic [15:0] i_wait(input pol, input [1:0] src, input [4:0] idx);
        i_wait = {3'b001, 5'd0, pol, src, idx};
    endfunction
    function automatic [15:0] i_in(input [2:0] src, input [5:0] n);    // n = 1..32
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
    // Fill in the delay/side-set field.
    function automatic [15:0] dss(input [15:0] ins, input [4:0] field);
        dss = ins | {3'b000, field, 8'd0};
    endfunction

    localparam [15:0] NOP = 16'hA042;   // mov y, y

    // Configuration register builders (RP2040 bit layout).
    function automatic [31:0] pinctrl_f(input [2:0] sideset_count, input [2:0] set_count,
                                        input [5:0] out_count, input [4:0] in_base,
                                        input [4:0] sideset_base, input [4:0] set_base,
                                        input [4:0] out_base);
        pinctrl_f = {sideset_count, set_count, out_count, in_base, sideset_base, set_base, out_base};
    endfunction
    function automatic [31:0] execctrl_f(input side_en, input side_pindir, input [4:0] jmp_pin,
                                         input [4:0] wrap_top, input [4:0] wrap_bottom,
                                         input status_sel, input [3:0] status_n);
        execctrl_f = {1'b0, side_en, side_pindir, jmp_pin, 5'd0, 1'b0, 1'b0,
                      wrap_top, wrap_bottom, 2'd0, status_sel, status_n};
    endfunction
    function automatic [31:0] shiftctrl_f(input [4:0] pull_thresh, input [4:0] push_thresh,
                                          input out_right, input in_right,
                                          input autopull, input autopush);
        shiftctrl_f = {2'd0, pull_thresh, push_thresh, out_right, in_right, autopull, autopush, 16'd0};
    endfunction

    // ------------------------------------------------------------------------
    // Event log: the cycle number of every RX push and TX pop
    // ------------------------------------------------------------------------

    int cyc;
    int rx_n, pop_n;
    reg [W-1:0] rx_log [0:63];
    int rx_cyc [0:63];
    int pop_cyc [0:63];

    always @(posedge clk) begin
        if (rx_push) begin
            rx_log[rx_n] = rx_data;
            rx_cyc[rx_n] = cyc;
            rx_n = rx_n + 1;
        end
        if (tx_pop) begin
            pop_cyc[pop_n] = cyc;
            pop_n = pop_n + 1;
        end
        cyc = cyc + 1;
    end

    // ------------------------------------------------------------------------
    // Helpers. The testbench changes inputs 1 ns after the rising edge and
    // checks results at the same point. Inputs must not change near the
    // falling edge because the scratch registers are written there.
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

    // Full reset with RP2040 reset values for the configuration registers.
    // Every instruction memory slot holds "jmp <self>". X and Y are not reset.
    task automatic reset_all();
        rst = 1;
        en = 0;
        restart = 0;
        clkdiv_restart = 0;
        host_tx_we = 0;
        host_tx_wdata = 0;
        host_rx_re = 0;
        host_irq_set = 0;
        host_irq_clr = 0;
        ext_in = 0;
        clkdiv = 32'h0001_0000;
        execctrl = 32'h0001_F000;
        shiftctrl = 32'h000C_0000;
        pinctrl = 32'h1400_0000;
        for (int i = 0; i < 32; i++)
            imem[i] = i_jmp(C_ALWAYS, i[4:0]);
        step(2);
        rst = 0;
        cyc = 0;
        rx_n = 0;
        pop_n = 0;
    endtask

    // Start the program; cycle 0 is the first cycle after this call.
    task automatic start();
        en = 1;
        cyc = 0;
        rx_n = 0;
        pop_n = 0;
    endtask

    // Host writes a word to the TX FIFO (takes one cycle).
    task automatic tx_put(input [W-1:0] w);
        if (tx_cnt == 3'd4)
            $fatal(1, "TX FIFO overflow in testbench");
        host_tx_we = 1;
        host_tx_wdata = w;
        step(1);
        host_tx_we = 0;
    endtask

    // Host reads a word from the RX FIFO (takes one cycle).
    task automatic rx_get(output [W-1:0] w);
        if (rx_cnt == 3'd0)
            $fatal(1, "RX FIFO underflow in testbench");
        w = rxf[rx_rd];
        host_rx_re = 1;
        step(1);
        host_rx_re = 0;
    endtask

    // Run a jump with the given condition after up to three setup
    // instructions. A taken jump lands on "jmp 10", a fall-through on "jmp 4".
    task automatic check_jmp(input [2:0] cond, input taken, input [15:0] s0,
                             input [15:0] s1, input [15:0] s2, input string what);
        imem[0] = s0;
        imem[1] = s1;
        imem[2] = s2;
        imem[3] = i_jmp(cond, 10);
        start();
        step(6);
        check(pc, taken ? 10 : 4, what);
    endtask

    // Watch an UART frame on gpio_out[pin]: start bit, 8 data bits LSB
    // first, stop bit, each exactly bit_cycles long. Waits for the start bit.
    task automatic uart_frame(input int pin, input int bit_cycles, output [7:0] data);
        int guard;
        reg [9:0] frame;
        guard = 0;
        while (gpio_out[pin] !== 1'b0) begin
            step(1);
            guard++;
            if (guard > 2000)
                $fatal(1, "UART: no start bit");
        end
        for (int b = 0; b < 10; b++) begin
            frame[b] = gpio_out[pin];
            for (int c = 0; c < bit_cycles; c++) begin
                if (gpio_out[pin] !== frame[b])
                    $fatal(1, "UART: bit %0d changed after %0d of %0d cycles", b, c, bit_cycles);
                if (b < 9 || c < bit_cycles - 1)
                    step(1);
            end
        end
        if (frame[0] !== 1'b0 || frame[9] !== 1'b1)
            $fatal(1, "UART: bad start/stop bits %b", frame);
        data = frame[8:1];
    endtask

    reg [W-1:0] word;
    reg [7:0] byte_rx;
    int ticks;

    initial begin
        reset_all();

        // ====================================================================
        // 1. Encoders match pioasm output from the datasheet
        // ====================================================================
        check(i_set(S_PINDIRS, 1), 16'hE081, "set pindirs, 1");
        check(dss(i_set(S_PINS, 1), 1), 16'hE101, "set pins, 1 [1]");
        check(i_pull(0, 1), 16'h80A0, "pull block");
        check(i_push(0, 1), 16'h8020, "push block");
        check(i_out(O_X, 32), 16'h6020, "out x, 32");
        check(i_in(IN_X, 32), 16'h4020, "in x, 32");
        check(dss(i_pull(0, 1), 5'h1F), 16'h9FA0, "uart_tx: pull side 1 [7]");
        check(dss(i_set(S_X, 7), 5'h17), 16'hF727, "uart_tx: set x, 7 side 0 [7]");
        check(i_out(O_PINS, 1), 16'h6001, "uart_tx: out pins, 1");
        check(dss(i_jmp(C_X_DEC, 2), 5'h06), 16'h0642, "uart_tx: jmp x-- 2 [6]");

        // ====================================================================
        // 2. One instruction per cycle, SET, and program wrap
        //    (squarewave_fast: wrap_target = 1, wrap = 2)
        // ====================================================================
        reset_all();
        imem[0] = i_set(S_PINDIRS, 1);
        imem[1] = i_set(S_PINS, 1);
        imem[2] = i_set(S_PINS, 0);
        execctrl = execctrl_f(0, 0, 0, 2, 1, 0, 0);
        pinctrl = pinctrl_f(0, 1, 0, 0, 0, 3, 0);      // SET -> GPIO 3
        // Disabled: the PC is held by branching to itself.
        #1;
        check(dut.branch_en, 1, "disabled: branch_en");
        check(dut.branch_addr, 0, "disabled: branch_addr");
        start();
        #1;
        check(dut.branch_en, 0, "pc 0: increments");
        step(1);
        check(gpio_oe[3], 1, "set pindirs");
        check(pc, 1, "pc after set pindirs");
        for (int i = 0; i < 10; i++) begin
            check(dut.branch_en, (pc == 2), "wrap: branch_en");
            check(dut.branch_addr, (pc == 2) ? 1 : 2, "wrap: branch_addr");
            step(1);
            check(gpio_out[3], (i % 2 == 0), "squarewave level");
            check(pc, (i % 2 == 0) ? 2 : 1, "squarewave pc");
        end

        // ====================================================================
        // 3. Delay cycles hold the PC (squarewave_wrap: period 4)
        // ====================================================================
        reset_all();
        imem[0] = i_set(S_PINDIRS, 1);
        imem[1] = dss(i_set(S_PINS, 1), 1);
        imem[2] = dss(i_set(S_PINS, 0), 1);
        execctrl = execctrl_f(0, 0, 0, 2, 1, 0, 0);
        pinctrl = pinctrl_f(0, 1, 0, 0, 0, 3, 0);
        start();
        step(1);
        for (int i = 0; i < 12; i++) begin
            step(1);
            check(gpio_out[3], (i % 4) < 2, "delayed squarewave level");
            check(pc, ((i % 4) < 2) ? 2 : 1, "delayed squarewave pc");
            check(dut.delay_cnt, (i % 2 == 0) ? 1 : 0, "delay counter");
        end

        // ====================================================================
        // 4. Clock divider and SM enable
        // ====================================================================
        reset_all();
        imem[0] = i_set(S_PINDIRS, 1);
        imem[1] = i_set(S_PINS, 1);
        imem[2] = i_set(S_PINS, 0);
        execctrl = execctrl_f(0, 0, 0, 2, 1, 0, 0);
        pinctrl = pinctrl_f(0, 1, 0, 0, 0, 3, 0);
        clkdiv = {16'd3, 8'd0, 8'd0};                    // divide by 3
        start();
        // Instruction j runs in cycle 3j: set pindirs, then 1, 0, 1, ...
        for (int k = 1; k <= 30; k++) begin
            step(1);
            check(gpio_out[3], ((k - 1) / 3) % 2, "divide-by-3 level");
            check(pc, ((k - 1) / 3) % 2 + 1, "divide-by-3 pc");
        end
        // Disabling holds the PC and the pins.
        en = 0;
        word = W'(pc);
        step(10);
        check(pc, word, "pc while disabled");
        check(gpio_out[3], ((30 - 1) / 3) % 2, "level while disabled");

        // Divide by 2.5: exactly 40 instructions in 100 cycles.
        reset_all();
        imem[0] = i_jmp(C_ALWAYS, 1);
        imem[1] = i_jmp(C_ALWAYS, 0);
        clkdiv = {16'd2, 8'h80, 8'd0};
        start();
        #1;
        ticks = 0;
        for (int k = 0; k < 100; k++) begin
            if (dut.done)
                ticks++;
            step(1);
        end
        check(ticks, 40, "instructions in 100 cycles at divisor 2.5");

        // ====================================================================
        // 5. JMP conditions, taken and not taken
        // ====================================================================
        reset_all();
        execctrl = execctrl_f(0, 0, 9, 31, 0, 0, 0);     // JMP_PIN = GPIO 9
        check_jmp(C_ALWAYS, 1, NOP, NOP, NOP, "jmp always");
        reset_all();
        check_jmp(C_NOT_X, 1, i_set(S_X, 0), NOP, NOP, "jmp !x, x = 0");
        reset_all();
        check_jmp(C_NOT_X, 0, i_set(S_X, 1), NOP, NOP, "jmp !x, x = 1");
        reset_all();
        check_jmp(C_X_DEC, 1, i_set(S_X, 1), NOP, NOP, "jmp x--, x = 1");
        check(dut.x, 0, "x after jmp x-- from 1");
        reset_all();
        check_jmp(C_X_DEC, 0, i_set(S_X, 0), NOP, NOP, "jmp x--, x = 0");
        check(dut.x, 16'hFFFF, "x after jmp x-- from 0");
        reset_all();
        check_jmp(C_NOT_Y, 1, i_set(S_Y, 0), NOP, NOP, "jmp !y, y = 0");
        reset_all();
        check_jmp(C_NOT_Y, 0, i_set(S_Y, 7), NOP, NOP, "jmp !y, y = 7");
        reset_all();
        check_jmp(C_Y_DEC, 1, i_set(S_Y, 2), NOP, NOP, "jmp y--, y = 2");
        check(dut.y, 1, "y after jmp y-- from 2");
        reset_all();
        check_jmp(C_Y_DEC, 0, i_set(S_Y, 0), NOP, NOP, "jmp y--, y = 0");
        check(dut.y, 16'hFFFF, "y after jmp y-- from 0");
        reset_all();
        check_jmp(C_X_NE_Y, 0, i_set(S_X, 3), i_set(S_Y, 3), NOP, "jmp x!=y, equal");
        reset_all();
        check_jmp(C_X_NE_Y, 1, i_set(S_X, 3), i_set(S_Y, 4), NOP, "jmp x!=y, different");
        reset_all();
        execctrl = execctrl_f(0, 0, 9, 31, 0, 0, 0);
        ext_in[9] = 1;
        check_jmp(C_PIN, 1, NOP, NOP, NOP, "jmp pin, pin high");
        reset_all();
        execctrl = execctrl_f(0, 0, 9, 31, 0, 0, 0);
        ext_in[8] = 1;
        ext_in[10] = 1;
        check_jmp(C_PIN, 0, NOP, NOP, NOP, "jmp pin, pin low");
        // !OSRE: the OSR is empty after reset, full after a PULL.
        reset_all();
        check_jmp(C_NOT_OSRE, 0, NOP, NOP, NOP, "jmp !osre, empty");
        reset_all();
        tx_put(16'h1234);
        check_jmp(C_NOT_OSRE, 1, i_pull(0, 1), NOP, NOP, "jmp !osre, after pull");
        // With PULL_THRESH = 8, the OSR counts as empty after 8 bits.
        reset_all();
        shiftctrl = shiftctrl_f(8, 0, 1, 1, 0, 0);
        tx_put(16'h1234);
        check_jmp(C_NOT_OSRE, 1, i_pull(0, 1), i_out(O_NULL, 4), NOP, "jmp !osre, 4 of 8 bits out");
        reset_all();
        shiftctrl = shiftctrl_f(8, 0, 1, 1, 0, 0);
        tx_put(16'h1234);
        check_jmp(C_NOT_OSRE, 0, i_pull(0, 1), i_out(O_NULL, 8), NOP, "jmp !osre, 8 of 8 bits out");

        // ====================================================================
        // 6. X-- loop, cycle by cycle. The regfile writes X at the falling
        //    edge; the branch must still use X before the decrement.
        // ====================================================================
        reset_all();
        imem[0] = i_set(S_X, 3);
        imem[1] = i_jmp(C_X_DEC, 1);
        imem[2] = i_jmp(C_ALWAYS, 2);
        start();
        step(1);
        check(dut.x, 3, "loop: set x");
        for (int i = 3; i >= 0; i--) begin
            @(negedge clk);
            #1;     // after the regfile write, before the PC update
            check(dut.x, i - 1, "loop: x after falling edge");
            check(dut.branch_addr, (i != 0) ? 1 : 2, "loop: branch_addr");
            @(posedge clk);
            #1;
            check(pc, (i != 0) ? 1 : 2, "loop: pc");
        end

        // ====================================================================
        // 7. Autopull and autopush loopback (datasheet figure 44)
        // ====================================================================
        reset_all();
        imem[0] = i_out(O_X, 16);
        imem[1] = i_in(IN_X, 16);
        execctrl = execctrl_f(0, 0, 0, 1, 0, 0, 0);
        shiftctrl = shiftctrl_f(0, 0, 1, 1, 1, 1);
        tx_put(16'h1111);
        tx_put(16'h2222);
        tx_put(16'h3333);
        tx_put(16'h4444);
        start();
        step(14);
        // OUT stalls in cycle 0 while the OSR fills, then the OSR refills
        // in the same cycle as each OUT, and each IN pushes straight away.
        check(pop_n, 4, "loopback: pops");
        check(pop_cyc[0], 0, "loopback: pop 0 during the first OUT stall");
        check(pop_cyc[1], 1, "loopback: pop 1 with the first OUT");
        check(pop_cyc[2], 3, "loopback: pop 2");
        check(pop_cyc[3], 5, "loopback: pop 3");
        check(rx_n, 4, "loopback: pushes");
        for (int i = 0; i < 4; i++) begin
            check(rx_log[i], 16'h1111 * (i + 1), "loopback: data");
            check(rx_cyc[i], 2 + 2 * i, "loopback: push cycle");
        end
        check(dut.isr_cnt, 0, "loopback: ISR count stays 0");
        // TX drained: OUT stalls with the OSR empty.
        check(pc, 0, "loopback: stalled on OUT");
        check(dut.stall, 1, "loopback: stall flag");
        check(dut.osr_cnt, W, "loopback: OSR empty");
        // RX is now full. One more word: OUT runs, then IN stalls on autopush.
        tx_put(16'h5555);
        step(4);
        check(pc, 1, "loopback: IN stalled on full RX FIFO");
        check(dut.stall, 1, "loopback: autopush stall");
        check(rx_n, 4, "loopback: no push while full");
        rx_get(word);
        check(word, 16'h1111, "loopback: host read");
        step(1);
        check(rx_n, 5, "loopback: push after host read");
        check(rx_log[4], 16'h5555, "loopback: fifth word");
        check(pc, 0, "loopback: IN completed");

        // ====================================================================
        // 8. PULL, OUT PINS, IN PINS, PUSH in both shift directions
        // ====================================================================
        for (int dir = 0; dir < 2; dir++) begin
            reset_all();
            imem[0] = i_set(S_PINDIRS, 5'hF);
            imem[1] = i_pull(0, 1);
            imem[2] = i_out(O_PINS, 4);
            imem[3] = i_in(IN_PINS, 4);
            imem[4] = i_out(O_PINS, 4);
            imem[5] = i_in(IN_PINS, 4);
            imem[6] = i_push(0, 1);
            imem[7] = i_jmp(C_ALWAYS, 7);
            pinctrl = pinctrl_f(0, 4, 4, 8, 0, 8, 8);    // OUT, SET, IN on GPIO 8..11
            if (dir == 0) begin
                // OUT right (LSB first), IN left.
                shiftctrl = shiftctrl_f(0, 0, 1, 0, 0, 0);
                tx_put(16'h00A5);
            end else begin
                // OUT left (MSB first), IN right.
                shiftctrl = shiftctrl_f(0, 0, 0, 1, 0, 0);
                tx_put(16'hA500);
            end
            start();
            step(3);
            check(gpio_out[11:8], (dir == 0) ? 4'h5 : 4'hA, "first nibble on pins");
            step(2);
            check(gpio_out[11:8], (dir == 0) ? 4'hA : 4'h5, "second nibble on pins");
            step(1);
            check(dut.isr_cnt, 8, "ISR count before push");
            check(dut.isr_q, (dir == 0) ? 16'h005A : 16'h5A00, "ISR before push");
            step(1);
            check(rx_n, 1, "push");
            check(rx_log[0], (dir == 0) ? 16'h005A : 16'h5A00, "pushed word");
            check(dut.isr_q, 0, "ISR cleared by push");
            check(dut.isr_cnt, 0, "ISR count cleared by push");
        end

        // ====================================================================
        // 9. Blocking, non-blocking and conditional PUSH / PULL
        // ====================================================================
        // PULL NOBLOCK on an empty TX FIFO copies X; PULL BLOCK stalls.
        reset_all();
        imem[0] = i_set(S_X, 28);
        imem[1] = i_pull(0, 0);
        imem[2] = i_mov(MD_Y, MOP_NONE, MS_OSR);
        imem[3] = i_pull(0, 1);
        imem[4] = i_jmp(C_ALWAYS, 4);
        start();
        step(3);
        check(dut.y, 28, "pull noblock copies X");
        check(dut.osr_cnt, 0, "pull noblock fills the OSR");
        step(5);
        check(pc, 3, "pull block stalls on empty FIFO");
        tx_put(16'hCAFE);
        step(1);
        check(pc, 4, "pull block completes");
        check(dut.osr_q, 16'hCAFE, "pull block data");

        // PUSH NOBLOCK on a full RX FIFO drops the data; PUSH BLOCK stalls.
        reset_all();
        imem[0] = i_set(S_X, 9);
        imem[1] = i_in(IN_X, 32);
        imem[2] = i_push(0, 0);
        imem[3] = i_in(IN_X, 32);
        imem[4] = i_push(0, 1);
        imem[5] = i_jmp(C_ALWAYS, 5);
        rx_cnt = 4;                                      // RX FIFO full
        start();
        step(3);
        check(rx_n, 0, "push noblock: nothing pushed");
        check(dut.isr_q, 0, "push noblock: ISR cleared");
        check(pc, 3, "push noblock: no stall");
        step(5);
        check(pc, 4, "push block stalls on full FIFO");
        check(rx_n, 0, "push block: nothing pushed yet");
        rx_get(word);
        step(1);
        check(rx_n, 1, "push block completes");
        check(rx_log[0], 9, "push block data");
        check(pc, 5, "push block pc");

        // PULL IFEMPTY and PUSH IFFULL with thresholds of 8.
        reset_all();
        shiftctrl = shiftctrl_f(8, 8, 1, 0, 0, 0);
        imem[0] = i_pull(0, 1);
        imem[1] = i_out(O_NULL, 4);
        imem[2] = i_pull(1, 1);
        imem[3] = i_out(O_NULL, 4);
        imem[4] = i_pull(1, 1);
        imem[5] = i_set(S_X, 3);
        imem[6] = i_in(IN_X, 4);
        imem[7] = i_push(1, 1);
        imem[8] = i_in(IN_X, 4);
        imem[9] = i_push(1, 1);
        imem[10] = i_jmp(C_ALWAYS, 10);
        tx_put(16'h00FF);
        tx_put(16'hAB00);
        start();
        step(3);
        check(tx_level, 1, "pull ifempty below threshold is a no-op");
        step(2);
        check(tx_level, 0, "pull ifempty at threshold pulls");
        check(dut.osr_q, 16'hAB00, "pull ifempty data");
        step(3);
        check(rx_n, 0, "push iffull below threshold is a no-op");
        check(dut.isr_cnt, 4, "push iffull no-op keeps the ISR");
        step(2);
        check(rx_n, 1, "push iffull at threshold pushes");
        check(rx_log[0], 16'h33, "push iffull data");

        // With autopull, PULL is a no-op while the OSR is full, and the OSR
        // refills in the background between OUTs.
        reset_all();
        shiftctrl = shiftctrl_f(0, 0, 1, 1, 1, 0);
        imem[0] = i_pull(0, 1);
        imem[1] = i_pull(0, 1);
        imem[2] = i_out(O_X, 32);
        imem[3] = NOP;
        imem[4] = i_jmp(C_ALWAYS, 4);
        tx_put(16'hAA01);
        tx_put(16'hAA02);
        start();
        step(2);
        check(tx_level, 1, "autopull: second PULL is a no-op");
        check(dut.osr_q, 16'hAA01, "autopull: OSR after PULL");
        step(1);
        check(dut.x, 16'hAA01, "autopull: OUT");
        check(dut.osr_q, 16'hAA02, "autopull: refill with the OUT");
        step(1);
        tx_put(16'hAA03);                           // OSR not empty: no refill
        step(2);
        check(tx_level, 1, "autopull: no refill while OSR is full");

        reset_all();
        shiftctrl = shiftctrl_f(0, 0, 1, 1, 1, 0);
        imem[0] = NOP;
        imem[1] = i_jmp(C_ALWAYS, 1);
        start();
        step(3);
        tx_put(16'hBEEF);
        step(1);
        check(dut.osr_q, 16'hBEEF, "background autopull");
        check(dut.osr_cnt, 0, "background autopull count");

        // ====================================================================
        // 10. MOV: operations, sources and destinations
        // ====================================================================
        reset_all();
        imem[0] = i_set(S_X, 1);
        imem[1] = i_mov(MD_Y, MOP_REV, MS_X);
        imem[2] = i_mov(MD_ISR, MOP_INV, MS_Y);
        imem[3] = i_mov(MD_OSR, MOP_INV, MS_NULL);
        imem[4] = i_mov(MD_X, MOP_NONE, MS_ISR);
        imem[5] = i_mov(MD_PINS, MOP_NONE, MS_X);
        imem[6] = i_mov(MD_Y, MOP_NONE, MS_PINS);
        imem[7] = i_mov(MD_X, MOP_NONE, MS_STATUS);
        imem[8] = i_jmp(C_ALWAYS, 8);
        pinctrl = pinctrl_f(0, 0, 8, 12, 0, 0, 8);        // OUT GPIO 8..15, IN_BASE 12
        execctrl = execctrl_f(0, 0, 0, 31, 0, 0, 2);      // STATUS: TX level < 2
        ext_in = 16'hF003;
        start();
        step(2);
        check(dut.y, 16'h8000, "mov y, ::x");
        step(1);
        check(dut.isr_q, 16'h7FFF, "mov isr, !y");
        check(dut.isr_cnt, 0, "mov isr clears count");
        step(1);
        check(dut.osr_q, 16'hFFFF, "mov osr, !null");
        check(dut.osr_cnt, 0, "mov osr clears count");
        step(1);
        check(dut.x, 16'h7FFF, "mov x, isr");
        check(pins_we, 16'hFF00, "mov pins: write mask is OUT_COUNT pins");
        check(pins_wdata & pins_we, 16'hFF00, "mov pins: data");
        step(1);
        check(gpio_out, 16'hFF00, "mov pins result");
        step(1);
        check(dut.y, 16'h003F, "mov y, pins rotates by IN_BASE");
        step(1);
        check(dut.x, 16'hFFFF, "mov x, status (TX empty < 2)");

        reset_all();
        imem[0] = i_mov(MD_X, MOP_NONE, MS_STATUS);
        imem[1] = i_jmp(C_ALWAYS, 1);
        execctrl = execctrl_f(0, 0, 0, 31, 0, 0, 2);
        tx_put(1);
        tx_put(2);
        start();
        step(1);
        check(dut.x, 0, "mov x, status (TX level 2)");
        reset_all();
        imem[0] = i_mov(MD_Y, MOP_NONE, MS_STATUS);
        imem[1] = i_jmp(C_ALWAYS, 1);
        execctrl = execctrl_f(0, 0, 0, 31, 0, 1, 1);      // STATUS: RX level < 1
        start();
        step(1);
        check(dut.y, 16'hFFFF, "mov y, status (RX empty < 1)");

        // ====================================================================
        // 11. Side-set
        // ====================================================================
        // spi_tx_fast: data on GPIO 3, clock by side-set on GPIO 2.
        reset_all();
        imem[0] = dss(i_out(O_PINS, 1), 5'b00000);       // out pins, 1  side 0
        imem[1] = dss(i_jmp(C_ALWAYS, 0), 5'b10000);     // jmp 0        side 1
        pinctrl = pinctrl_f(1, 0, 1, 0, 2, 0, 3);
        shiftctrl = shiftctrl_f(8, 0, 1, 1, 1, 0);       // autopull every 8 bits
        tx_put(16'h00A5);
        start();
        step(1);                                         // OUT stalls, OSR fills
        check(pc, 0, "spi: first OUT stalls");
        for (int i = 0; i < 8; i++) begin
            step(1);
            check(gpio_out[2], 0, "spi: clock low with data");
            check(gpio_out[3], (8'hA5 >> i) & 1, "spi: data bit");
            step(1);
            check(gpio_out[2], 1, "spi: clock high");
            check(gpio_out[3], (8'hA5 >> i) & 1, "spi: data held");
        end
        // TX empty: OUT stalls, but its side-set still drives the clock low.
        for (int i = 0; i < 4; i++) begin
            step(1);
            check(pc, 0, "spi: stalled on empty FIFO");
            check(gpio_out[2], 0, "spi: side-set during stall");
            check(pins_we[3], 0, "spi: no OUT during stall");
        end

        // Optional side-set (SIDE_EN) with delay bits.
        reset_all();
        imem[0] = dss(i_set(S_X, 0), 5'b11010);          // side 1 [2]
        imem[1] = dss(i_set(S_X, 1), 5'b00001);          // no side-set, [1]
        imem[2] = dss(i_set(S_X, 2), 5'b10000);          // side 0
        imem[3] = i_jmp(C_ALWAYS, 3);
        pinctrl = pinctrl_f(2, 0, 0, 0, 5, 0, 0);        // 2 bits incl. enable, GPIO 5
        execctrl = execctrl_f(1, 0, 0, 31, 0, 0, 0);
        start();
        #1;
        check(pins_we, 16'h0020, "side_en: write mask");
        step(1);
        check(gpio_out[5], 1, "side_en: side 1");
        step(2);
        check(pc, 1, "side_en: two delay cycles");
        check(pins_we, 0, "side_en: no side-set without the enable bit");
        step(1);
        check(dut.x, 1, "side_en: set x, 1");
        check(gpio_out[5], 1, "side_en: pin unchanged");
        step(2);
        check(gpio_out[5], 0, "side_en: side 0");
        check(dut.x, 2, "side_en: set x, 2");

        // Side-set wins over SET on the same pin; SIDE_PINDIR drives directions.
        reset_all();
        imem[0] = dss(i_set(S_PINS, 1), 5'b00000);       // set pins, 1 side 0
        imem[1] = dss(i_set(S_PINS, 0), 5'b10000);       // set pins, 0 side 1
        imem[2] = i_jmp(C_ALWAYS, 2);
        pinctrl = pinctrl_f(1, 1, 0, 0, 6, 6, 0);
        start();
        step(1);
        check(gpio_out[6], 0, "side-set wins over set (side 0)");
        step(1);
        check(gpio_out[6], 1, "side-set wins over set (side 1)");
        reset_all();
        imem[0] = dss(i_set(S_PINS, 1), 5'b10000);       // set pins, 1 side 1
        imem[1] = i_jmp(C_ALWAYS, 1);
        pinctrl = pinctrl_f(1, 1, 0, 0, 6, 6, 0);
        execctrl = execctrl_f(0, 1, 0, 31, 0, 0, 0);     // SIDE_PINDIR
        start();
        step(1);
        check(gpio_out[6], 1, "side_pindir: set pins");
        check(gpio_oe[6], 1, "side_pindir: side-set to direction");

        // ====================================================================
        // 12. WAIT
        // ====================================================================
        // WAIT GPIO; delay cycles start after the wait completes.
        reset_all();
        imem[0] = dss(i_wait(1, W_GPIO, 14), 2);
        imem[1] = i_set(S_PINS, 1);
        imem[2] = i_jmp(C_ALWAYS, 2);
        pinctrl = pinctrl_f(0, 1, 0, 0, 0, 0, 0);
        start();
        step(5);
        check(pc, 0, "wait gpio: stalled");
        check(dut.delay_cnt, 0, "wait gpio: no delay while stalled");
        ext_in[14] = 1;
        step(1);
        check(pc, 1, "wait gpio: done");
        step(2);
        check(gpio_out[0], 0, "wait gpio: delay cycles");
        step(1);
        check(gpio_out[0], 1, "wait gpio: next instruction");

        // WAIT PIN uses IN_BASE: pin 3 with IN_BASE 10 is GPIO 13.
        reset_all();
        imem[0] = i_wait(0, W_PIN, 3);
        imem[1] = i_jmp(C_ALWAYS, 1);
        pinctrl = pinctrl_f(0, 0, 0, 10, 0, 0, 0);
        ext_in = 16'h2000;
        start();
        step(3);
        check(pc, 0, "wait pin: stalled on GPIO 13");
        ext_in = 16'h0008;                          // GPIO 3 is not mapped
        step(1);
        check(pc, 1, "wait pin: done");

        // WAIT 1 IRQ clears the flag; relative index 0x13 on SM 1 is flag 0.
        reset_all();
        imem[0] = i_wait(1, W_IRQ, 5);
        imem[1] = i_wait(0, W_IRQ, 2);
        imem[2] = i_wait(1, W_IRQ, 5'h13);
        imem[3] = i_jmp(C_ALWAYS, 3);
        start();
        step(3);
        check(pc, 0, "wait irq 5: stalled");
        host_irq_set = 8'h20;
        step(1);
        host_irq_set = 0;
        step(1);
        check(pc, 1, "wait irq 5: done");
        check(irq_flags, 0, "wait irq 5: flag cleared");
        step(1);
        check(pc, 2, "wait 0 irq 2: flag already low");
        host_irq_set = 8'h08;                            // flag 3: wrong flag
        step(1);
        host_irq_set = 0;
        step(2);
        check(pc, 2, "wait irq rel: not flag 3");
        host_irq_set = 8'h01;                            // flag 0
        step(1);
        host_irq_set = 0;
        step(1);
        check(pc, 3, "wait irq rel: flag 0");
        check(irq_flags, 8'h08, "wait irq rel: only flag 0 cleared");

        // ====================================================================
        // 13. IRQ set, clear, wait and relative indices
        // ====================================================================
        reset_all();
        imem[0] = i_irq(0, 0, 3);                        // irq set 3
        imem[1] = i_irq(0, 0, 5'h16);                    // irq set 6 rel -> 7
        imem[2] = i_irq(1, 0, 3);                        // irq clear 3
        imem[3] = i_irq(0, 1, 4);                        // irq wait 4
        imem[4] = i_set(S_X, 30);
        imem[5] = i_jmp(C_ALWAYS, 5);
        start();
        step(1);
        check(irq_flags, 8'h08, "irq set 3");
        step(1);
        check(irq_flags, 8'h88, "irq set 6 rel");
        step(1);
        check(irq_flags, 8'h80, "irq clear 3");
        step(1);
        check(irq_flags, 8'h90, "irq wait sets flag 4");
        check(pc, 3, "irq wait: stalled");
        step(4);
        check(pc, 3, "irq wait: still stalled");
        check(irq_set, 0, "irq wait: flag set only once");
        host_irq_clr = 8'h10;
        step(1);
        host_irq_clr = 0;
        step(1);
        check(pc, 4, "irq wait: done after clear");
        step(1);
        check(dut.x, 30, "irq wait: next instruction");

        // ====================================================================
        // 14. OUT PC, MOV PC
        // ====================================================================
        reset_all();
        imem[0] = i_pull(0, 1);
        imem[1] = i_out(O_PC, 5);
        imem[12] = i_set(S_Y, 14);
        imem[13] = i_mov(MD_PC, MOP_NONE, MS_Y);
        imem[14] = i_set(S_X, 1);
        imem[15] = i_jmp(C_ALWAYS, 15);
        tx_put(12);
        start();
        step(2);
        check(pc, 12, "out pc");
        step(2);
        check(pc, 14, "mov pc");
        step(1);
        check(dut.x, 1, "after mov pc");

        // ====================================================================
        // 15. SM_RESTART clears internal state but keeps X, Y and the PC
        // ====================================================================
        reset_all();
        shiftctrl = shiftctrl_f(0, 0, 1, 0, 0, 0);
        imem[0] = i_pull(0, 1);
        imem[1] = i_set(S_X, 5);
        imem[2] = i_in(IN_X, 8);
        imem[3] = dss(i_set(S_Y, 6), 7);
        imem[4] = i_jmp(C_ALWAYS, 4);
        tx_put(16'h1234);
        start();
        step(5);
        check(dut.osr_cnt, 0, "restart: OSR full before");
        check(dut.isr_cnt, 8, "restart: ISR count before");
        check(dut.delay_cnt, 6, "restart: delay before");
        restart = 1;
        step(1);
        restart = 0;
        check(dut.isr_q, 0, "restart: ISR cleared");
        check(dut.isr_cnt, 0, "restart: ISR count cleared");
        check(dut.osr_cnt, W, "restart: OSR count = W (empty)");
        check(dut.delay_cnt, 0, "restart: delay cleared");
        check(dut.x, 5, "restart: X kept");
        check(dut.y, 6, "restart: Y kept");
        check(pc, 4, "restart: pc kept");

        reset_all();
        imem[0] = i_irq(0, 1, 2);
        start();
        step(2);
        check(dut.irq_waiting, 1, "restart: waiting on IRQ");
        restart = 1;
        step(1);
        restart = 0;
        check(dut.irq_waiting, 0, "restart: IRQ wait cleared");

        // ====================================================================
        // 16. DATA_WIDTH limits: bit counts clamp to W, pin numbers wrap mod W
        // ====================================================================
        reset_all();
        shiftctrl = shiftctrl_f(0, 0, 1, 1, 0, 0);
        pinctrl = pinctrl_f(0, 1, 0, 0, 0, 20, 0);       // SET_BASE 20 -> GPIO 4
        imem[0] = i_pull(0, 1);
        imem[1] = i_out(O_X, 20);                        // 20 > W: shifts W bits
        imem[2] = i_set(S_PINS, 1);
        imem[3] = i_in(IN_X, 24);                        // 24 > W: shifts W bits
        imem[4] = i_jmp(C_ALWAYS, 4);
        tx_put(16'hBEEF);
        start();
        step(2);
        check(dut.x, 16'hBEEF, "width: out count clamped");
        check(dut.osr_cnt, W, "width: OSR empty after clamped out");
        step(1);
        check(gpio_out, 16'h0010, "width: set base wraps mod W");
        step(1);
        check(dut.isr_q, 16'hBEEF, "width: in count clamped");
        check(dut.isr_cnt, W, "width: ISR full after clamped in");

        // ====================================================================
        // 17. End to end: uart_tx from the datasheet, at two baud rates
        // ====================================================================
        for (int div = 1; div <= 3; div += 2) begin
            reset_all();
            imem[0] = 16'h9FA0;                          // pull side 1 [7]
            imem[1] = 16'hF727;                          // set x, 7 side 0 [7]
            imem[2] = 16'h6001;                          // out pins, 1
            imem[3] = 16'h0642;                          // jmp x-- 2 [6]
            pinctrl = pinctrl_f(2, 0, 1, 0, 4, 0, 4);    // OUT and side-set on GPIO 4
            execctrl = execctrl_f(1, 0, 0, 3, 0, 0, 0);  // side-set optional, wrap 3 -> 0
            tx_put(16'h5A);
            tx_put(16'hC3);
            // Set the divisor last: the divider has been ticking every cycle
            // at divisor 1, so the first cycle after start() is a tick.
            clkdiv = {div[15:0], 8'd0, 8'd0};
            start();
            step(1);
            check(gpio_out[4], 1, $sformatf("uart div %0d: idle high", div));
            uart_frame(4, 8 * div, byte_rx);
            check(byte_rx, 8'h5A, "uart: first byte");
            uart_frame(4, 8 * div, byte_rx);
            check(byte_rx, 8'hC3, "uart: second byte");
            // TX empty: line stays high, SM stalls on PULL.
            step(40 * div);
            check(gpio_out[4], 1, "uart: idle after frames");
            check(pc, 0, "uart: waiting on PULL");
        end

        $display("SM SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
