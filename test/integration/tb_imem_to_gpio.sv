`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_imem_to_gpio.fst"
`endif
// Assembler output (assembler_test.py) and the program list. The Makefile
// passes absolute paths; these defaults work from test/.
`ifndef HEX_DIR
`define HEX_DIR "integration/assembler_test_outputs/generated"
`endif
`ifndef GOLDEN_DIR
`define GOLDEN_DIR "integration/assembler_test_outputs/golden"
`endif
`ifndef PROG_LIST
`define PROG_LIST "integration/programs.txt"
`endif

// Integration: instruction memory -> SM -> FIFOs / GPIO controller
// (imem_to_gpio.md).
//
// The functional checks of tb_sm_no_smx_instr.sv, run on real blocks instead
// of testbench models:
//   * instruction memory: the IHP 64x16 SRAM model, preloaded with $readmemh
//     from the assembler's hex image of each program (pio_programs/*.pio);
//   * TX and RX FIFOs: fifo.sv;
//   * GPIO: gpio_controller.sv with its default pin map (GPIO 0-3 input only,
//     4-11 bidirectional, 12-15 output only). The pads loop back: a driven
//     pad reads its own level, other pads read ext_in.
// IRQ flags are still a testbench model (there is no IRQ block yet).
//
// Programs listed as expected failures in programs.txt (IRQ, which the
// assembler emits as NOP while it is reserved) are loaded from the golden
// image instead, so the SM checks still mean something.
//
// Differences from tb_sm_no_smx_instr.sv:
//   * Pins are moved onto GPIOs that support the access (see the .pio
//     files), and pin-level checks look at the GPIO controller's pads.
//   * test_gpio_fault raises real faults through the GPIO controller instead
//     of forcing gpio_fault, and also checks the controller's reaction.
//   * Any GPIO fault outside test_gpio_fault is an error.
//   * test_mov: MOV Y, PINS reads GPIO 12-15 (output only) as 0.
//   * test_push_blocking fills the RX FIFO with real writes.
//   * test_boot and test_instruction_encoders are not repeated: every
//     program's boot is checked against its image, and the assembler test
//     covers encoding.
//
// TX FIFO fall-through: the SM pops and reads tx_data in the same cycle, but
// fifo.sv's d_out is registered. Until fifo.sv is first-word fall-through,
// tx_data comes from its interim combinational `head` port. When it is:
//   * connect u_tx_fifo.d_out to tx_data and drop `head` (here and in
//     fifo.sv);
//   * re-check tx_empty / tx_level if the FWFT FIFO derives them
//     differently (e.g. an output register that holds one extra word);
//   * rx_get() reads d_out on the cycle after the pop; with a fall-through
//     d_out, read it before the pop instead.
module tb_imem_to_gpio;
    // SM_ID = 1 so that relative IRQ indices differ from absolute ones.
    localparam [1:0] SM_ID = 2'd1;
    localparam int W = 16;
    localparam int DEPTH = 4;
    localparam int IMAGE_WORDS = 40;           // 32 program slots + 8 config words

    reg clk;
    reg rst;                                    // FIFOs, GPIO controller, IRQ model
    reg sm_rst;                                 // the SM, held until boot()
    reg en;
    reg restart;
    reg clkdiv_restart;
    reg booted;

    // Instruction memory
    wire [5:0]  mem_addr;
    wire        read_en;
    wire [15:0] instr;
    wire [5:0]  pc = dut.pc;

    // TX FIFO (host -> SM)
    reg          host_tx_we;
    reg  [W-1:0] host_tx_wdata;
    wire [W-1:0] tx_data;
    wire         tx_empty;
    wire [2:0]   tx_level;
    wire         tx_pop;
    wire [2:0]   tx_wptr, tx_rptr;

    // RX FIFO (SM -> host). tb_rx_we lets a test fill it before the SM runs.
    wire [W-1:0] rx_data;
    wire         rx_full;
    wire [2:0]   rx_level;
    wire         rx_push;
    reg          host_rx_re;
    reg          tb_rx_we;
    reg  [W-1:0] tb_rx_wdata;
    wire [W-1:0] rx_dout;
    wire [2:0]   rx_wptr, rx_rptr;

    // GPIO
    wire [W-1:0] gpio_in, pins_we, pins_wdata, dirs_we, dirs_wdata, pins_re;
    wire         gpio_fault;
    reg          clr_fault;
    wire         fault;
    wire [2:0]   fault_cause;
    wire [W-1:0] pad_in, pad_out, pad_oe;
    reg  [W-1:0] ext_in;                        // external level on undriven pads
    wire [W-1:0] gpio_out = pad_out;
    wire [W-1:0] gpio_oe = pad_oe;

    // IRQ flags (testbench model)
    reg  [7:0] irq_flags;
    wire [7:0] irq_set, irq_clr;
    reg  [7:0] host_irq_set, host_irq_clr;

    sm_no_smx_instr #(.SM_ID(SM_ID), .DATA_WIDTH(W)) dut (
        .clk(clk),
        .external_rst(sm_rst),
        .imem_loaded(1'b1),                     // memory is preloaded by the tb
        .en(en),
        .restart(restart),
        .clkdiv_restart(clkdiv_restart),
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
        .pins_re(pins_re),
        .gpio_fault(gpio_fault),
        .irq_flags(irq_flags),
        .irq_set(irq_set),
        .irq_clr(irq_clr)
    );

    RM_IHPSG13_1P_64x16_c2 u_imem (
        .A_CLK(clk),
        .A_MEN(1'b1),
        .A_WEN(1'b0),                           // preloaded with $readmemh
        .A_REN(read_en),
        .A_ADDR(mem_addr),
        .A_DIN(16'h0000),
        .A_DLY(1'b1),
        .A_DOUT(instr)
    );

    fifo #(.DEPTH(DEPTH), .DATA_WIDTH(W)) u_tx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(host_tx_wdata),
        .w_en(host_tx_we),
        .r_en(tx_pop),
        .d_out(),
        .head(tx_data),                         // interim fall-through read, see above
        .wptr(tx_wptr),
        .rptr(tx_rptr)
    );
    assign tx_level = tx_wptr - tx_rptr;
    assign tx_empty = (tx_level == 3'd0);

    fifo #(.DEPTH(DEPTH), .DATA_WIDTH(W)) u_rx_fifo (
        .clk(clk),
        .rst(rst),
        .d_in(tb_rx_we ? tb_rx_wdata : rx_data),
        .w_en(rx_push | tb_rx_we),
        .r_en(host_rx_re),
        .d_out(rx_dout),
        .head(),
        .wptr(rx_wptr),
        .rptr(rx_rptr)
    );
    assign rx_level = rx_wptr - rx_rptr;
    assign rx_full = (rx_level == 3'(DEPTH));

    gpio_controller #(.DATA_WIDTH(W)) u_gpio (  // default pin map
        .clk(clk),
        .rst(rst),
        .pins_we(pins_we),
        .pins_wdata(pins_wdata),
        .dirs_we(dirs_we),
        .dirs_wdata(dirs_wdata),
        .pins_re(pins_re),
        .gpio_in(gpio_in),
        .gpio_fault(gpio_fault),
        .clr_fault(clr_fault),
        .fault(fault),
        .fault_cause(fault_cause),
        .pad_in(pad_in),
        .pad_out(pad_out),
        .pad_oe(pad_oe)
    );
    assign pad_in = (pad_oe & pad_out) | (~pad_oe & ext_in);

    always @(posedge clk) begin
        if (rst)
            irq_flags <= 8'd0;
        else
            irq_flags <= (irq_flags & ~(irq_clr | host_irq_clr)) | irq_set | host_irq_set;
    end

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_imem_to_gpio);
    end

`ifdef SV_TEST
    localparam [15:0] NOP = 16'hA042;           // mov y, y
    localparam [W-1:0] BIDIR = 16'h0FF0;

    // ------------------------------------------------------------------------
    // Results: failures per program
    // ------------------------------------------------------------------------

    string cur_prog;
    reg    cur_golden;                          // loaded from the golden image
    int    failures;
    int    n_progs;
    string prog_names [0:127];
    int    prog_fails [0:127];
    reg    prog_golden [0:127];

    task automatic fail(input string msg);
        failures++;
        if (n_progs > 0)
            prog_fails[n_progs - 1]++;
        $error("[%s] %s", cur_prog, msg);
    endtask

    task automatic check(input [31:0] got, input [31:0] exp, input string what);
        if (got !== exp)
            fail($sformatf("%s: got %h, expected %h", what, got, exp));
    endtask

    // Expected failures from programs.txt: lines with a third '|' field.
    string xfail_names [0:31];
    int    n_xfail;

    // Icarus has no string.getc(), so each line is scanned as raw bytes:
    // $fgets right-aligns the line, first character in the highest nonzero
    // byte.
    localparam int LINE_BYTES = 256;

    task automatic read_prog_list();
        int fd, bars;
        bit started, comment, xfail_text;
        reg [8*LINE_BYTES-1:0] raw;
        reg [7:0] c;
        string name;
        n_xfail = 0;
        fd = $fopen(`PROG_LIST, "r");
        if (fd == 0)
            $fatal(1, "cannot open %s", `PROG_LIST);
        raw = 0;
        while ($fgets(raw, fd)) begin
            started = 0;
            comment = 0;
            bars = 0;
            xfail_text = 0;
            for (int i = LINE_BYTES - 1; i >= 0; i--) begin
                c = raw[8*i +: 8];
                if (c != 0) begin
                    if (!started && c == "#")
                        comment = 1;
                    started = 1;
                    if (c == "|")
                        bars++;
                    else if (bars >= 2 && c != " " && c != "\t" && c != "\n" && c != "\r")
                        xfail_text = 1;
                end
            end
            if (!comment && xfail_text && $sscanf(raw, "%s", name) == 1) begin
                xfail_names[n_xfail] = name;
                n_xfail++;
            end
            raw = 0;
        end
        $fclose(fd);
    endtask

    function automatic bit is_xfail(input string name);
        for (int i = 0; i < n_xfail; i++)
            if (xfail_names[i] == name)
                return 1;
        return 0;
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

    // Only test_gpio_fault may fault.
    reg fault_expected;
    always @(posedge clk)
        if (!rst && gpio_fault === 1'b1 && !fault_expected)
            fail($sformatf("unexpected GPIO fault at pc %0d: {read, dir, drive} = %b",
                           pc, {u_gpio.bad_read, u_gpio.bad_dir, u_gpio.bad_drive}));

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

    // Reset everything. The SM stays in reset until boot(), which start()
    // runs if a test hasn't. X and Y are not reset.
    task automatic reset_all();
        rst = 1;
        sm_rst = 1;
        booted = 0;
        en = 0;
        restart = 0;
        clkdiv_restart = 0;
        host_tx_we = 0;
        host_tx_wdata = 0;
        host_rx_re = 0;
        tb_rx_we = 0;
        tb_rx_wdata = 0;
        host_irq_set = 0;
        host_irq_clr = 0;
        clr_fault = 0;
        ext_in = 0;
        fault_expected = 0;
        step(2);
        rst = 0;
        cyc = 0;
        rx_n = 0;
        pop_n = 0;
    endtask

    // Preload the instruction memory with a program's hex image: 32 program
    // slots, then CLKDIV, EXECCTRL, SHIFTCTRL, PINCTRL (low half first).
    reg [15:0] img [0:IMAGE_WORDS-1];

    task automatic load(input string name);
        string path;
        int fd;
        cur_prog = name;
        cur_golden = is_xfail(name);
        path = {cur_golden ? `GOLDEN_DIR : `HEX_DIR, "/", name, ".hex"};
        prog_names[n_progs] = name;
        prog_fails[n_progs] = 0;
        prog_golden[n_progs] = cur_golden;
        n_progs++;
        fd = $fopen(path, "r");
        if (fd == 0)
            $fatal(1, "missing %s (run assembler_test.py)", path);
        $fclose(fd);
        for (int i = 0; i < IMAGE_WORDS; i++)
            img[i] = 'x;
        $readmemh(path, img);
        $readmemh(path, u_imem.i_SRAM_1P_behavioral.memory, 0, IMAGE_WORDS - 1);
        for (int i = 0; i < IMAGE_WORDS; i++)
            if (img[i] === 16'hxxxx)
                fail($sformatf("%s: line %0d missing", path, i + 1));
    endtask

    // Release the SM reset and let it load its config from memory 32-39 (8
    // cycles). Afterwards the PC is 0 and the next cycle is the first
    // program cycle.
    task automatic boot();
        step(1);                                // the SRAM re-reads 32 after the preload
        sm_rst = 0;
        step(8);
        booted = 1;
        check(pc, 0, "boot: pc 0 after loading the config");
        check(dut.booting, 0, "boot: finished");
        check(dut.clkdiv, {img[33], img[32]}, "boot: CLKDIV from imem");
        check(dut.execctrl, {img[35], img[34]}, "boot: EXECCTRL from imem");
        check(dut.shiftctrl, {img[37], img[36]}, "boot: SHIFTCTRL from imem");
        check(dut.pinctrl, {img[39], img[38]}, "boot: PINCTRL from imem");
    endtask

    // Start the program; cycle 0 is the first cycle after this call.
    task automatic start();
        if (!booted)
            boot();
        en = 1;
        cyc = 0;
        rx_n = 0;
        pop_n = 0;
    endtask

    // Host writes a word to the TX FIFO (takes one cycle).
    task automatic tx_put(input [W-1:0] w);
        if (tx_level == 3'(DEPTH))
            $fatal(1, "TX FIFO overflow in testbench");
        host_tx_we = 1;
        host_tx_wdata = w;
        step(1);
        host_tx_we = 0;
    endtask

    // Host reads a word from the RX FIFO (takes one cycle). d_out is
    // registered: it holds the popped word after the edge.
    task automatic rx_get(output [W-1:0] w);
        if (rx_level == 3'd0)
            $fatal(1, "RX FIFO underflow in testbench");
        host_rx_re = 1;
        step(1);
        host_rx_re = 0;
        w = rx_dout;
    endtask

    // Write a word into the RX FIFO from the testbench (SM not running).
    task automatic rx_fill(input [W-1:0] w);
        tb_rx_we = 1;
        tb_rx_wdata = w;
        step(1);
        tb_rx_we = 0;
    endtask

    // Run test_jmp_conditions_<n>: a jump after up to three setup
    // instructions. A taken jump lands on "jmp 10", a fall-through on
    // "jmp 4"; both jump to themselves so the PC stays put for the check.
    task automatic check_jmp(input int n, input taken, input string what);
        load($sformatf("test_jmp_conditions_%0d", n));
        start();
        step(6);
        check(pc, taken ? 10 : 4, what);
    endtask

    // Watch a UART frame on gpio_out[pin]: start bit, 8 data bits LSB
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

    // ------------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------------

    task automatic test_set_and_wrap();
        // One instruction per cycle, SET, and program wrap
        // (squarewave_fast: wrap_target = 1, wrap = 2), SET on GPIO 4.
        reset_all();
        load("test_set_and_wrap");
        boot();
        // Disabled: the PC is held by branching to itself.
        #1;
        check(dut.branch_en, 1, "disabled: branch_en");
        check(dut.branch_addr, 0, "disabled: branch_addr");
        start();
        #1;
        check(dut.branch_en, 0, "pc 0: increments");
        step(1);
        check(gpio_oe[4], 1, "set pindirs: pad driven");
        check(pc, 1, "pc after set pindirs");
        for (int i = 0; i < 10; i++) begin
            check(dut.branch_en, (pc == 2), "wrap: branch_en");
            check(dut.branch_addr, (pc == 2) ? 1 : 2, "wrap: branch_addr");
            step(1);
            check(gpio_out[4], (i % 2 == 0), "squarewave level");
            check(pad_in[4], (i % 2 == 0), "squarewave on the pad");
            check(pc, (i % 2 == 0) ? 2 : 1, "squarewave pc");
        end
    endtask

    task automatic test_delay();
        // Delay cycles hold the PC (squarewave_wrap: period 4).
        reset_all();
        load("test_delay");
        start();
        step(1);
        for (int i = 0; i < 12; i++) begin
            step(1);
            check(gpio_out[4], (i % 4) < 2, "delayed squarewave level");
            check(pc, ((i % 4) < 2) ? 2 : 1, "delayed squarewave pc");
            check(dut.delay_cnt, (i % 2 == 0) ? 1 : 0, "delay counter");
        end
    endtask

    task automatic test_clock_divider_and_enable();
        int ticks;
        reg [W-1:0] word;
        // Clock divider and SM enable
        reset_all();
        load("test_clock_divider_and_enable_0");   // divide by 3
        start();
        // Instruction j runs in cycle 3j: set pindirs, then 1, 0, 1, ...
        for (int k = 1; k <= 30; k++) begin
            step(1);
            check(gpio_out[4], ((k - 1) / 3) % 2, "divide-by-3 level");
            check(pc, ((k - 1) / 3) % 2 + 1, "divide-by-3 pc");
        end
        // Disabling holds the PC and the pins.
        en = 0;
        word = W'(pc);
        step(10);
        check(pc, word, "pc while disabled");
        check(gpio_out[4], ((30 - 1) / 3) % 2, "level while disabled");

        // Divide by 2.5: exactly 40 instructions in 100 cycles.
        reset_all();
        load("test_clock_divider_and_enable_1");
        start();
        #1;
        ticks = 0;
        for (int k = 0; k < 100; k++) begin
            if (dut.done)
                ticks++;
            step(1);
        end
        check(ticks, 40, "instructions in 100 cycles at divisor 2.5");
    endtask

    task automatic test_jmp_conditions();
        // JMP conditions, taken and not taken. JMP_PIN = GPIO 9.
        reset_all();
        check_jmp(0, 1, "jmp always");
        reset_all();
        check_jmp(1, 1, "jmp !x, x = 0");
        reset_all();
        check_jmp(2, 0, "jmp !x, x = 1");
        reset_all();
        check_jmp(3, 1, "jmp x--, x = 1");
        check(dut.x, 0, "x after jmp x-- from 1");
        reset_all();
        check_jmp(4, 0, "jmp x--, x = 0");
        check(dut.x, 16'hFFFF, "x after jmp x-- from 0");
        reset_all();
        check_jmp(5, 1, "jmp !y, y = 0");
        reset_all();
        check_jmp(6, 0, "jmp !y, y = 7");
        reset_all();
        check_jmp(7, 1, "jmp y--, y = 2");
        check(dut.y, 1, "y after jmp y-- from 2");
        reset_all();
        check_jmp(8, 0, "jmp y--, y = 0");
        check(dut.y, 16'hFFFF, "y after jmp y-- from 0");
        reset_all();
        check_jmp(9, 0, "jmp x!=y, equal");
        reset_all();
        check_jmp(10, 1, "jmp x!=y, different");
        reset_all();
        ext_in[9] = 1;
        check_jmp(11, 1, "jmp pin, pin high");
        reset_all();
        ext_in[8] = 1;
        ext_in[10] = 1;
        check_jmp(12, 0, "jmp pin, pin low");
        // !OSRE: the OSR is empty after reset, full after a PULL.
        reset_all();
        check_jmp(13, 0, "jmp !osre, empty");
        reset_all();
        tx_put(16'h1234);
        check_jmp(14, 1, "jmp !osre, after pull");
        // With PULL_THRESH = 8, the OSR counts as empty after 8 bits.
        reset_all();
        tx_put(16'h1234);
        check_jmp(15, 1, "jmp !osre, 4 of 8 bits out");
        reset_all();
        tx_put(16'h1234);
        check_jmp(16, 0, "jmp !osre, 8 of 8 bits out");
    endtask

    task automatic test_jmp_x_dec_loop();
        // X-- loop, cycle by cycle. The regfile writes X at the falling
        // edge; the branch must still use X before the decrement.
        reset_all();
        load("test_jmp_x_dec_loop");
        start();
        step(1);
        check(dut.x, 3, "loop: set x");
        for (int i = 3; i >= 0; i--) begin
            int comp = i - 1;
            @(negedge clk);
            #1;     // after the regfile write, before the PC update
            check(dut.x, comp[15:0], "loop: x after falling edge");
            check(dut.branch_addr, (i != 0) ? 1 : 2, "loop: branch_addr");
            @(posedge clk);
            #1;
            check(pc, (i != 0) ? 1 : 2, "loop: pc");
        end
    endtask

    task automatic test_autopull_autopush_loopback();
        reg [W-1:0] word;
        // Autopull and autopush loopback (datasheet figure 44)
        reset_all();
        load("test_autopull_autopush_loopback");
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
        check(rx_level, 4, "loopback: RX FIFO full");
        check(dut.isr_cnt, 0, "loopback: ISR count stays 0");
        // TX drained: OUT stalls with the OSR empty.
        check(tx_level, 0, "loopback: TX FIFO empty");
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
        // The RX FIFO holds the remaining words in order.
        for (int i = 1; i < 5; i++) begin
            rx_get(word);
            check(word, 16'h1111 * (i + 1), "loopback: RX FIFO order");
        end
    endtask

    task automatic test_shift_and_pin_instructions();
        reg [W-1:0] word;
        // PULL, OUT PINS, IN PINS, PUSH in both shift directions, on GPIO
        // 8..11 (bidirectional).
        for (int dir = 0; dir < 2; dir++) begin
            reset_all();
            load($sformatf("test_shift_and_pin_instructions_%0d", dir));
            // dir 0: OUT right (LSB first), IN left. dir 1: the reverse.
            tx_put((dir == 0) ? 16'h00A5 : 16'hA500);
            start();
            step(3);
            check(gpio_out[11:8], (dir == 0) ? 4'h5 : 4'hA, "first nibble on pins");
            check(gpio_oe[11:8], 4'hF, "GPIO 8..11 driven");
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
            rx_get(word);
            check(word, (dir == 0) ? 16'h005A : 16'h5A00, "word in the RX FIFO");
        end
    endtask

    task automatic test_pull_blocking();
        // PULL NOBLOCK on an empty TX FIFO copies X; PULL BLOCK stalls.
        reset_all();
        load("test_pull_blocking");
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
        check(tx_level, 0, "pull block popped the TX FIFO");
    endtask

    task automatic test_push_blocking();
        reg [W-1:0] word;
        // PUSH NOBLOCK on a full RX FIFO drops the data; PUSH BLOCK stalls.
        reset_all();
        load("test_push_blocking");
        for (int i = 0; i < DEPTH; i++)
            rx_fill(16'hD000 + i);                      // RX FIFO full
        check(rx_full, 1, "push: RX FIFO full before start");
        start();
        step(3);
        check(rx_n, 0, "push noblock: nothing pushed");
        check(dut.isr_q, 0, "push noblock: ISR cleared");
        check(pc, 3, "push noblock: no stall");
        step(5);
        check(pc, 4, "push block stalls on full FIFO");
        check(rx_n, 0, "push block: nothing pushed yet");
        rx_get(word);
        check(word, 16'hD000, "push: host read the oldest word");
        step(1);
        check(rx_n, 1, "push block completes");
        check(rx_log[0], 9, "push block data");
        check(pc, 5, "push block pc");
        // Three fill words, then the pushed word.
        for (int i = 1; i <= DEPTH; i++) begin
            rx_get(word);
            check(word, (i < DEPTH) ? 16'hD000 + i : 9, "push: RX FIFO contents");
        end
    endtask

    task automatic test_pull_push_thresholds();
        // PULL IFEMPTY and PUSH IFFULL with thresholds of 8.
        reset_all();
        load("test_pull_push_thresholds");
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
    endtask

    task automatic test_pull_with_autopull();
        // With autopull, PULL is a no-op while the OSR is full, and the OSR
        // refills in the background between OUTs.
        reset_all();
        load("test_pull_with_autopull_0");
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
        load("test_pull_with_autopull_1");
        start();
        step(3);
        tx_put(16'hBEEF);
        step(1);
        check(dut.osr_q, 16'hBEEF, "background autopull");
        check(dut.osr_cnt, 0, "background autopull count");
    endtask

    task automatic test_mov();
        // MOV: operations, sources and destinations. OUT on GPIO 8..15,
        // IN_BASE 12.
        reset_all();
        load("test_mov_0");
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
        // GPIO 12-15 are output only and read as 0, so only GPIO 0-1
        // (ext_in 0x0003) arrive, rotated by IN_BASE 12 to bits 4-5.
        check(dut.y, 16'h0030, "mov y, pins rotates by IN_BASE");
        step(1);
        check(dut.x, 16'hFFFF, "mov x, status (TX empty < 2)");

        reset_all();
        load("test_mov_1");
        tx_put(1);
        tx_put(2);
        start();
        step(1);
        check(dut.x, 0, "mov x, status (TX level 2)");
        reset_all();
        load("test_mov_2");
        start();
        step(1);
        check(dut.y, 16'hFFFF, "mov y, status (RX empty < 1)");
    endtask

    task automatic test_sideset();
        // spi_tx_fast: data on GPIO 13, clock by side-set on GPIO 12 (both
        // output only).
        reset_all();
        load("test_sideset_0");
        tx_put(16'h00A5);
        start();
        step(1);                                         // OUT stalls, OSR fills
        check(pc, 0, "spi: first OUT stalls");
        for (int i = 0; i < 8; i++) begin
            step(1);
            check(gpio_out[12], 0, "spi: clock low with data");
            check(gpio_out[13], (8'hA5 >> i) & 1, "spi: data bit");
            step(1);
            check(gpio_out[12], 1, "spi: clock high");
            check(gpio_out[13], (8'hA5 >> i) & 1, "spi: data held");
        end
        // TX empty: OUT stalls, but its side-set still drives the clock low.
        for (int i = 0; i < 4; i++) begin
            step(1);
            check(pc, 0, "spi: stalled on empty FIFO");
            check(gpio_out[12], 0, "spi: side-set during stall");
            check(pins_we[13], 0, "spi: no OUT during stall");
        end

        // Optional side-set (SIDE_EN) with delay bits, GPIO 5.
        reset_all();
        load("test_sideset_1");
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
        load("test_sideset_2");
        start();
        step(1);
        check(gpio_out[6], 0, "side-set wins over set (side 0)");
        step(1);
        check(gpio_out[6], 1, "side-set wins over set (side 1)");
        reset_all();
        load("test_sideset_3");
        start();
        step(1);
        check(gpio_out[6], 1, "side_pindir: set pins");
        check(gpio_oe[6], 1, "side_pindir: side-set to direction");
    endtask

    task automatic test_wait();
        // WAIT GPIO 2 (input only); delay cycles start after the wait
        // completes. SET on GPIO 12.
        reset_all();
        load("test_wait_0");
        start();
        step(5);
        check(pc, 0, "wait gpio: stalled");
        check(dut.delay_cnt, 0, "wait gpio: no delay while stalled");
        ext_in[2] = 1;
        step(1);
        check(pc, 1, "wait gpio: done");
        step(2);
        check(gpio_out[12], 0, "wait gpio: delay cycles");
        step(1);
        check(gpio_out[12], 1, "wait gpio: next instruction");

        // WAIT PIN uses IN_BASE: pin 3 with IN_BASE 5 is GPIO 8.
        reset_all();
        load("test_wait_1");
        ext_in = 16'h0100;
        start();
        step(3);
        check(pc, 0, "wait pin: stalled on GPIO 8");
        ext_in = 16'h0008;                          // GPIO 3 is not mapped
        step(1);
        check(pc, 1, "wait pin: done");

        // WAIT 1 IRQ clears the flag; relative index 0x13 on SM 1 is flag 0.
        reset_all();
        load("test_wait_2");
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
    endtask

    task automatic test_irq();
        // IRQ set, clear, wait and relative indices
        reset_all();
        load("test_irq");
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
    endtask

    task automatic test_out_pc_and_mov_pc();
        reset_all();
        load("test_out_pc_and_mov_pc");
        tx_put(12);
        start();
        step(2);
        check(pc, 12, "out pc");
        step(2);
        check(pc, 14, "mov pc");
        step(1);
        check(dut.x, 1, "after mov pc");
    endtask

    task automatic test_sm_restart();
        // SM_RESTART clears internal state but keeps X, Y and the PC
        reset_all();
        load("test_sm_restart_0");
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
        load("test_sm_restart_1");
        start();
        step(2);
        check(dut.irq_waiting, 1, "restart: waiting on IRQ");
        restart = 1;
        step(1);
        restart = 0;
        check(dut.irq_waiting, 0, "restart: IRQ wait cleared");
    endtask

    task automatic test_data_width_limits();
        // DATA_WIDTH limits: bit counts clamp to W, pin numbers wrap mod W
        reset_all();
        load("test_data_width_limits");
        tx_put(16'hBEEF);
        start();
        step(2);
        check(dut.x, 16'hBEEF, "width: out count clamped");
        check(dut.osr_cnt, W, "width: OSR empty after clamped out");
        step(1);
        check(gpio_out, 16'h0010, "width: set base 20 wraps to GPIO 4");
        step(1);
        check(dut.isr_q, 16'hBEEF, "width: in count clamped");
        check(dut.isr_cnt, W, "width: ISR full after clamped in");
    endtask

    task automatic test_uart_tx();
        reg [7:0] byte_rx;
        // End to end: uart_tx from the datasheet at divisors 1 and 3, OUT and
        // side-set on GPIO 4.
        for (int n = 0; n < 2; n++) begin
            int div = (n == 0) ? 1 : 3;
            reset_all();
            load($sformatf("test_uart_tx_%0d", n));
            tx_put(16'h5A);
            tx_put(16'hC3);
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
    endtask

    task automatic test_gpio_fault();
        // GPIO faults raised by the GPIO controller with its default pin
        // map. The PC branches to FAULT_VEC (EXECCTRL[23:19]) on the fault
        // cycle; delay and a pending IRQ WAIT are cleared. The controller
        // blocks that cycle's writes, then holds the pads safe (BIDIR
        // released, outputs at SAFE_OUT = 0) and ignores writes until
        // clr_fault.
        localparam [4:0] FV = 5'd20;

        // 0) Drive fault: OUT PINS [3] on GPIO 0 (input only), a completed
        //    instruction with a delay.
        reset_all();
        fault_expected = 1;
        load("test_gpio_fault_0");
        start();
        step(2);
        check(pc, 2, "fault 0: at out pins, 1 [3]");
        check(gpio_oe[4], 1, "fault 0: GPIO 4 driven before the fault");
        check(gpio_out[4], 1, "fault 0: GPIO 4 high before the fault");
        check(dut.done, 1, "fault 0: instruction completes");
        check(pins_we, 16'h0001, "fault 0: writes GPIO 0");
        check(gpio_fault, 1, "fault 0: gpio_fault");
        check(dut.branch_en, 1, "fault 0: branch_en");
        check(dut.branch_addr, FV, "fault 0: branch_addr = FAULT_VEC");
        step(1);
        check(pc, FV, "fault 0: pc = FAULT_VEC");
        check(dut.delay_cnt, 0, "fault 0: delay cleared");
        check(fault, 1, "fault 0: sticky fault");
        check(fault_cause, 3'b001, "fault 0: cause = drive");
        check(u_gpio.out_q[0], 0, "fault 0: faulting write blocked");
        check(gpio_oe & BIDIR, 0, "fault 0: bidirectional pads released");
        check(gpio_out, 0, "fault 0: pads at SAFE_OUT");
        check(dut.done, 1, "fault 0: handler runs at once");
        check(gpio_fault, 0, "fault 0: handler's set pins is legal");
        step(1);
        check(pc, FV + 1, "fault 0: handler continues");
        check(u_gpio.out_q[4], 1, "fault 0: writes ignored while faulted");
        check(gpio_out[4], 0, "fault 0: pad held at SAFE_OUT");
        clr_fault = 1;
        step(1);
        clr_fault = 0;
        check(fault, 0, "fault 0: clr_fault clears the fault");
        check(fault_cause, 0, "fault 0: clr_fault clears the cause");
        check(u_gpio.out_q, 0, "fault 0: clr_fault resets the pin levels");
        check(gpio_oe & BIDIR, 0, "fault 0: clr_fault leaves pads as inputs");

        // 1) Read fault: WAIT GPIO 13 (output only). Nothing faults during
        //    the delay of the instruction before it.
        reset_all();
        fault_expected = 1;
        load("test_gpio_fault_1");
        start();
        step(2);
        check(pc, 1, "fault 1: past set x [5]");
        check(dut.delay_cnt, 4, "fault 1: in delay");
        check(dut.active, 0, "fault 1: not executing");
        check(pins_re, 0, "fault 1: no read during the delay");
        check(gpio_fault, 0, "fault 1: no fault during the delay");
        step(4);
        check(dut.active, 1, "fault 1: wait runs after the delay");
        check(dut.stall, 1, "fault 1: wait would stall");
        check(pins_re, 16'h2000, "fault 1: wait reads GPIO 13");
        check(gpio_fault, 1, "fault 1: gpio_fault");
        check(dut.branch_addr, FV, "fault 1: branch_addr = FAULT_VEC");
        step(1);
        check(pc, FV, "fault 1: pc = FAULT_VEC");
        check(fault_cause, 3'b100, "fault 1: cause = read");
        check(dut.x, 1, "fault 1: earlier instruction kept");
        step(2);
        check(pc, FV, "fault 1: stays in handler");

        // 2) IRQ WAIT 0 with side-set on GPIO 0 (input only): faults on its
        //    first cycle. The IRQ flag is still set, but the wait is dropped.
        reset_all();
        fault_expected = 1;
        load("test_gpio_fault_2");
        start();
        #1;
        check(dut.stall, 1, "fault 2: irq wait stalls");
        check(irq_set, 8'h01, "fault 2: irq wait sets flag 0");
        check(pins_we, 16'h0001, "fault 2: side-set writes GPIO 0");
        check(gpio_fault, 1, "fault 2: gpio_fault");
        check(dut.branch_addr, FV, "fault 2: branch_addr = FAULT_VEC");
        step(1);
        check(pc, FV, "fault 2: pc = FAULT_VEC");
        check(dut.irq_waiting, 0, "fault 2: irq_waiting cleared");
        check(irq_flags, 8'h01, "fault 2: flag 0 still set");
        check(fault_cause, 3'b001, "fault 2: cause = drive");
        step(1);
        check(pc, FV, "fault 2: stays in handler");
        check(gpio_fault, 0, "fault 2: handler is legal");

        // 3) FAULT_VEC 7 from EXECCTRL; SET PINDIRS on GPIO 12 (output only).
        reset_all();
        fault_expected = 1;
        load("test_gpio_fault_3");
        start();
        step(3);
        check(pc, 3, "fault 3: at set pindirs");
        check(dirs_we, 16'h1000, "fault 3: direction write on GPIO 12");
        check(gpio_fault, 1, "fault 3: gpio_fault");
        step(1);
        check(pc, 7, "fault 3: pc = FAULT_VEC 7");
        check(fault_cause, 3'b010, "fault 3: cause = dir");
        step(2);
        check(pc, 7, "fault 3: stays in handler");
    endtask

    task automatic test_pins_re();
        // pins_re: the GPIOs each instruction reads, for the GPIO controller
        reset_all();
        load("test_pins_re_0");                        // IN_BASE 4, SET -> GPIO 12
        ext_in = 16'h0240;                             // GPIO 6 and 9 high
        boot();
        #1;
        check(pins_re, 0, "pins_re: 0 while disabled");
        start();
        #1;
        check(pins_re, 16'h0070, "pins_re: in pins, 3");
        step(1);
        check(pins_re, 16'h0200, "pins_re: wait gpio 9");
        step(1);
        check(pins_re, 16'h0040, "pins_re: wait pin 2");
        step(1);
        check(pins_re, 16'h0200, "pins_re: jmp pin");
        step(1);
        check(pc, 4, "pins_re: jmp pin taken");
        check(pins_re, 0, "pins_re: mov x, pins not reported");
        step(1);
        check(pins_re, 0, "pins_re: set pins");
        step(1);
        check(gpio_out[12], 1, "pins_re: set pins on GPIO 12");

        // A stalled WAIT keeps reporting its pin.
        reset_all();
        load("test_pins_re_1");
        start();
        step(3);
        check(pc, 0, "pins_re: wait stalled");
        check(pins_re, 16'h0400, "pins_re: stalled wait gpio 10");
    endtask

    initial begin
        #50ms;
        $fatal(1, "timeout");
    end

    initial begin
        failures = 0;
        n_progs = 0;
        cur_prog = "";
        read_prog_list();
        test_set_and_wrap();
        test_delay();
        test_clock_divider_and_enable();
        test_jmp_conditions();
        test_jmp_x_dec_loop();
        test_autopull_autopush_loopback();
        test_shift_and_pin_instructions();
        test_pull_blocking();
        test_push_blocking();
        test_pull_push_thresholds();
        test_pull_with_autopull();
        test_mov();
        test_sideset();
        test_wait();
        test_irq();
        test_out_pc_and_mov_pc();
        test_sm_restart();
        test_data_width_limits();
        test_uart_tx();
        test_gpio_fault();
        test_pins_re();

        $display("");
        $display("imem -> SM -> FIFOs / GPIO controller, %0d programs:", n_progs);
        for (int i = 0; i < n_progs; i++)
            $display("  %-34s %s%s", prog_names[i], prog_fails[i] ? "FAIL" : "PASS",
                     prog_golden[i] ? "  (golden image: assembler emits NOP for IRQ)" : "");
        if (failures == 0) begin
            $display("imem_to_gpio integration test passed");
            $finish;
        end else
            $fatal(1, "imem_to_gpio integration test: %0d check(s) failed", failures);
    end
`endif
endmodule
