`timescale 1ns/10ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_spi_slave.fst"
`endif

module tb_spi_slave;
    parameter DATA_WIDTH = 16;

    logic clk;
    logic rst;
    logic cpol;
    logic cpha;
    logic sclk;
    logic cs_n;
    logic mosi;
    logic [DATA_WIDTH-1:0] tx_data;

    wire miso;
    wire miso_oe;
    wire [DATA_WIDTH-1:0] rx_data;
    wire rx_valid;
    int failures = 0;

    spi_slave #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cpol(cpol),
        .cpha(cpha),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .miso_oe(miso_oe),
        .tx_data(tx_data),
        .rx_data(rx_data),
        .rx_valid(rx_valid)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_spi_slave);
    end

`ifdef SV_TEST
    // 100 MHz system clock; the SPI clock is not a multiple of it, so sclk
    // edges land at varying points within the clk period.
    localparam real HALF_SCLK = 53.7;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    int rx_valid_count = 0;
    always @(posedge clk) if (rx_valid) rx_valid_count++;

    initial begin
        setup_test();
        mode_test(0, 0);
        mode_test(0, 1);
        mode_test(1, 0);
        mode_test(1, 1);
        back_to_back_test();
        abort_test();
        report_results();
    end

    // Master side of one word with cs_n already low. Drives mosi_word,
    // returns what the master sampled on miso.
    task automatic master_word(input logic [DATA_WIDTH-1:0] mosi_word,
                               output logic [DATA_WIDTH-1:0] miso_word);
        for (int i = DATA_WIDTH - 1; i >= 0; i--) begin
            if (!cpha) begin
                mosi = mosi_word[i];          // set up before the leading edge
                #(HALF_SCLK);
                sclk = ~cpol;                 // leading: both sides sample
                miso_word[i] = miso;
                #(HALF_SCLK);
                sclk = cpol;                  // trailing: both sides shift
            end else begin
                sclk = ~cpol;                 // leading: both sides shift
                mosi = mosi_word[i];
                #(HALF_SCLK);
                sclk = cpol;                  // trailing: both sides sample
                miso_word[i] = miso;
                #(HALF_SCLK);
            end
        end
    endtask

    task automatic check_xfer(input string name,
                              input logic [DATA_WIDTH-1:0] sent,
                              input logic [DATA_WIDTH-1:0] got_miso,
                              input logic [DATA_WIDTH-1:0] exp_miso);
        if (rx_data !== sent) begin
            failures++;
            $error("%s: rx_data=%h expected %h", name, rx_data, sent);
        end
        if (got_miso !== exp_miso) begin
            failures++;
            $error("%s: master read miso=%h expected %h", name, got_miso, exp_miso);
        end
    endtask

    task automatic mode_test(input logic pol, input logic pha);
        logic [DATA_WIDTH-1:0] got;
        logic [DATA_WIDTH-1:0] words [3];
        string name;
        $sformat(name, "mode cpol=%0d cpha=%0d", pol, pha);
        words[0] = 16'hA5C3;
        words[1] = 16'h0001;
        words[2] = 16'h8000;

        cpol = pol;
        cpha = pha;
        sclk = pol;
        #(4 * HALF_SCLK);

        foreach (words[k]) begin
            int count_before = rx_valid_count;
            tx_data = ~words[k] ^ 16'h1234;
            #(2 * HALF_SCLK);
            cs_n = 0;
            #(HALF_SCLK);
            master_word(words[k], got);
            #(HALF_SCLK);
            cs_n = 1;
            #(2 * HALF_SCLK);
            check_xfer(name, words[k], got, ~words[k] ^ 16'h1234);
            if (rx_valid_count != count_before + 1) begin
                failures++;
                $error("%s: rx_valid pulsed %0d times", name, rx_valid_count - count_before);
            end
        end

        // Random words in this mode.
        repeat (20) begin
            logic [DATA_WIDTH-1:0] w = $urandom;
            logic [DATA_WIDTH-1:0] t = $urandom;
            tx_data = t;
            #(2 * HALF_SCLK);
            cs_n = 0;
            #(HALF_SCLK + ($urandom % 10));
            master_word(w, got);
            #(HALF_SCLK);
            cs_n = 1;
            #(2 * HALF_SCLK);
            check_xfer(name, w, got, t);
        end
    endtask

    // Two words in one cs_n low period, in every mode. The first word is
    // captured while cs_n is high, so the host queues the second word in
    // tx_data during the first transfer.
    task automatic back_to_back_test();
        logic [DATA_WIDTH-1:0] got0, got1;
        for (int m = 0; m < 4; m++) begin
            cpol = m[1];
            cpha = m[0];
            sclk = cpol;
            tx_data = 16'hBEEF;
            #(4 * HALF_SCLK);
            cs_n = 0;
            #(HALF_SCLK);
            fork
                begin
                    master_word(16'h1357, got0);
                    master_word(16'h2468, got1);
                end
                begin
                    #(4 * HALF_SCLK) tx_data = 16'hCAFE;
                    do @(posedge clk); while (!rx_valid);
                    if (rx_data !== 16'h1357) begin
                        failures++;
                        $error("back-to-back mode %0d: first word rx_data=%h", m, rx_data);
                    end
                end
            join
            #(HALF_SCLK);
            cs_n = 1;
            #(2 * HALF_SCLK);
            if (rx_data !== 16'h2468 || got0 !== 16'hBEEF || got1 !== 16'hCAFE) begin
                failures++;
                $error("back-to-back mode %0d: rx=%h miso0=%h miso1=%h", m, rx_data, got0, got1);
            end
        end
    endtask

    // cs_n rising mid-word drops the partial word; the next word is clean.
    task automatic abort_test();
        logic [DATA_WIDTH-1:0] got;
        int count_before;
        cpol = 0;
        cpha = 0;
        sclk = 0;
        tx_data = 16'h0F0F;
        #(4 * HALF_SCLK);
        count_before = rx_valid_count;
        cs_n = 0;
        #(HALF_SCLK);
        for (int i = 0; i < 5; i++) begin
            mosi = 1;
            #(HALF_SCLK) sclk = 1;
            #(HALF_SCLK) sclk = 0;
        end
        #(HALF_SCLK);
        cs_n = 1;
        #(2 * HALF_SCLK);
        if (rx_valid_count != count_before) begin
            failures++;
            $error("abort: rx_valid pulsed on a partial word");
        end
        cs_n = 0;
        #(HALF_SCLK);
        master_word(16'h4242, got);
        #(HALF_SCLK);
        cs_n = 1;
        #(2 * HALF_SCLK);
        check_xfer("abort", 16'h4242, got, 16'h0F0F);
    endtask

    task setup_test();
        rst = 1;
        cpol = 0;
        cpha = 0;
        sclk = 0;
        cs_n = 1;
        mosi = 0;
        tx_data = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    task report_results();
        if (failures == 0)
            $display("SPI slave tests passed");
        else
            $display("SPI slave tests: %0d case(s) failed", failures);
        $finish;
    endtask

`endif
endmodule
