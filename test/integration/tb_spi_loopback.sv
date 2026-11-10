`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_spi_loopback.fst"
`endif

// spi_master (src/integration) wired straight to spi_slave (src/modules).
// Each transfer sends one word each way; both ends must receive the other's
// word in every CPOL / CPHA mode.
module tb_spi_loopback;
    parameter DATA_WIDTH = 16;
    parameter CLK_DIV    = 4;

    logic clk;
    logic rst;
    logic cpol;
    logic cpha;
    logic start;
    logic [DATA_WIDTH-1:0] m_tx_data;
    logic [DATA_WIDTH-1:0] s_tx_data;

    wire sclk;
    wire cs_n;
    wire mosi;
    wire miso;
    wire miso_oe;
    wire busy;
    wire [DATA_WIDTH-1:0] m_rx_data;
    wire [DATA_WIDTH-1:0] s_rx_data;
    wire m_rx_valid;
    wire s_rx_valid;
    int failures = 0;

    spi_master #(
        .DATA_WIDTH(DATA_WIDTH),
        .CLK_DIV(CLK_DIV)
    ) master (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .start(start),
        .tx_data(m_tx_data),
        .busy(busy),
        .rx_data(m_rx_data),
        .rx_valid(m_rx_valid)
    );

    spi_slave #(
        .DATA_WIDTH(DATA_WIDTH)
    ) slave (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .miso_oe(miso_oe),
        .tx_data(s_tx_data),
        .rx_data(s_rx_data),
        .rx_valid(s_rx_valid)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_spi_loopback);
    end

`ifdef SV_TEST
    // 100 MHz system clock shared by master and slave.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    int m_valid_count = 0;
    int s_valid_count = 0;
    always @(posedge clk) begin
        if (m_rx_valid) m_valid_count++;
        if (s_rx_valid) s_valid_count++;
    end

    // sclk must sit at its idle level whenever cs_n is high. The master
    // registers sclk, so it follows a cpol change one clk cycle later.
    logic cpol_d;
    always @(posedge clk) begin
        if (!rst && cs_n && cpol === cpol_d && sclk !== cpol) begin
            failures++;
            $error("sclk=%b while deselected, expected idle level %b", sclk, cpol);
        end
        cpol_d <= cpol;
    end

    initial begin
        setup_test();
        mode_test(0, 0);
        mode_test(0, 1);
        mode_test(1, 0);
        mode_test(1, 1);
        start_while_busy_test();
        report_results();
    end

    // One full frame: the master sends m_word while the slave sends s_word.
    // Returns once the master has dropped busy.
    task automatic xfer(input logic [DATA_WIDTH-1:0] m_word,
                        input logic [DATA_WIDTH-1:0] s_word);
        @(negedge clk);
        m_tx_data = m_word;
        s_tx_data = s_word;
        start = 1;
        @(negedge clk);
        start = 0;
        if (!busy) begin
            failures++;
            $error("busy did not rise after start");
        end
        wait (!busy);
        @(negedge clk);
    endtask

    task automatic check_xfer(input string name,
                              input logic [DATA_WIDTH-1:0] m_word,
                              input logic [DATA_WIDTH-1:0] s_word,
                              input int m_count_before,
                              input int s_count_before);
        if (s_rx_data !== m_word) begin
            failures++;
            $error("%s: slave rx_data=%h expected %h", name, s_rx_data, m_word);
        end
        if (m_rx_data !== s_word) begin
            failures++;
            $error("%s: master rx_data=%h expected %h", name, m_rx_data, s_word);
        end
        if (m_valid_count != m_count_before + 1) begin
            failures++;
            $error("%s: master rx_valid pulsed %0d times", name, m_valid_count - m_count_before);
        end
        if (s_valid_count != s_count_before + 1) begin
            failures++;
            $error("%s: slave rx_valid pulsed %0d times", name, s_valid_count - s_count_before);
        end
        if (cs_n !== 1'b1) begin
            failures++;
            $error("%s: cs_n still low after busy fell", name);
        end
    endtask

    task automatic mode_test(input logic pol, input logic pha);
        logic [DATA_WIDTH-1:0] words [4];
        string name;
        $sformat(name, "mode cpol=%0d cpha=%0d", pol, pha);
        words[0] = 16'hA5C3;
        words[1] = 16'h0001;
        words[2] = 16'h8000;
        words[3] = 16'hFFFF;

        @(negedge clk);
        cpol = pol;
        cpha = pha;
        repeat (4 * CLK_DIV) @(negedge clk);

        foreach (words[k]) begin
            int mc = m_valid_count;
            int sc = s_valid_count;
            xfer(words[k], ~words[k] ^ 16'h1234);
            check_xfer(name, words[k], ~words[k] ^ 16'h1234, mc, sc);
        end

        // Random words, with random gaps between frames.
        repeat (20) begin
            logic [DATA_WIDTH-1:0] m_word = $urandom;
            logic [DATA_WIDTH-1:0] s_word = $urandom;
            int mc = m_valid_count;
            int sc = s_valid_count;
            repeat ($urandom % 8) @(negedge clk);
            xfer(m_word, s_word);
            check_xfer(name, m_word, s_word, mc, sc);
        end
    endtask

    // A start pulse during a frame is ignored: it neither restarts the
    // frame nor queues a second one, and tx_data changes mid-frame are not
    // picked up.
    task automatic start_while_busy_test();
        int mc, sc;
        @(negedge clk);
        cpol = 0;
        cpha = 0;
        repeat (4 * CLK_DIV) @(negedge clk);
        mc = m_valid_count;
        sc = s_valid_count;

        m_tx_data = 16'h1357;
        s_tx_data = 16'h2468;
        start = 1;
        @(negedge clk);
        start = 0;
        repeat (8 * CLK_DIV) @(negedge clk);
        m_tx_data = 16'hDEAD;
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
        @(negedge clk);
        check_xfer("start while busy", 16'h1357, 16'h2468, mc, sc);

        repeat (4 * CLK_DIV) @(negedge clk);
        if (busy || m_valid_count != mc + 1) begin
            failures++;
            $error("start while busy: a second frame was started");
        end
    endtask

    task setup_test();
        rst = 1;
        cpol = 0;
        cpha = 0;
        start = 0;
        m_tx_data = '0;
        s_tx_data = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    task report_results();
        if (failures == 0)
            $display("SPI loopback tests passed");
        else
            $display("SPI loopback tests: %0d case(s) failed", failures);
        $finish;
    endtask

`endif
endmodule
