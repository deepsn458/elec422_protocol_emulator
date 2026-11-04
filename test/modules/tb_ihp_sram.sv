`timescale 1ns/1ps
`ifndef TB_DUMPFILE
`define TB_DUMPFILE "tb_ihp_sram.fst"
`endif

module tb_ihp_sram;
    reg clk = 0;
    reg men = 0;
    reg wen = 0;
    reg ren = 0;
    reg [5:0] addr = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;

    always #5 clk = ~clk;

    RM_IHPSG13_1P_64x16_c2 dut (
        .A_CLK(clk),
        .A_MEN(men),
        .A_WEN(wen),
        .A_REN(ren),
        .A_ADDR(addr),
        .A_DIN(din),
        .A_DLY(1'b1),
        .A_DOUT(dout)
    );

    initial begin
        $dumpfile(`TB_DUMPFILE);
        $dumpvars(0, tb_ihp_sram);
    end

`ifdef SV_TEST
    initial begin
        // Write without read enable: output retains its previous value.
        $display("<< write without read enable: output retains its previous value >>");
        @(negedge clk);
        men = 1;
        wen = 1;
        addr = 1;
        
        din = 16'h1234;
        @(posedge clk);
        #1;

        // A read is synchronous. Dout is valid on the cycle following the one
        // in which a valid address is passed in
        @(negedge clk);
        wen = 0;
        ren = 1;
        repeat(2)@(posedge clk);
        #1;
        $display("din=%h, dout=%h", din, dout);
        if (dout !== 16'h1234)
            $error(1, "SRAM readback at address 0 failed: %h", dout);

        // MEN gates writes and reads, and the registered output holds.
        $display("<< write without memory enable: registered output holds >>");
        @(negedge clk);
        men = 0;
        wen = 1;
        din = 16'hdead;
        @(posedge clk);
        #1;
        $display("din=%h, dout=%h", din, dout);
        if (dout !== 16'h1234)
            $error(1, "SRAM output changed while disabled: %h", dout);

        $display("<< read without memory enable: what is the output of dout??");
        @(negedge clk);
        men = 0;
        ren = 1;
        @(posedge clk);
        #1;
        $display("dout: %h",dout);

        $display("<< print dout without read enable >>");
        @(negedge clk);
        men = 1;
        ren = 0;
        @(posedge clk);
        #1
        $display("dout: %h", dout);

        // Simultaneous write and read returns the new data (write-through).
        $display("<< Simultaneous write and read returns the new data >>");
        @(negedge clk);
        addr = 6'd63;
        wen = 1;
        ren = 1;
        din = 16'hbeef;
        @(posedge clk);
        #1;
        $display("din=%h, dout=%h", din, dout);
        if (dout !== 16'hbeef)
            $error(1, "SRAM write-through at address 63 failed: %h", dout);

        @(negedge clk);
        wen = 0;
        @(posedge clk);
        #1;
        if (dout !== 16'hbeef)
            $error(1, "SRAM readback at address 63 failed: %h", dout);

        // A read request does not change DOUT before the sampling edge.
        // Address 1 contains dead, while the last output is beef.
        @(negedge clk);
        addr = 6'd1;
        #1;
        if (dout !== 16'hbeef)
            $error(1, "SRAM output changed before the read clock edge: %h", dout);
        $display("before read edge: ren=%b addr=%d dout=%h", ren, addr, dout);
        @(posedge clk);
        #1;
        if (dout !== 16'hdead)
            $error(1, "SRAM output did not update after the read clock edge: %h", dout);
        $display("after read edge:  ren=%b addr=%d dout=%h", ren, addr, dout);

        $display($time,"IHP SRAM SystemVerilog test passed");
        $finish;
    end
`endif
endmodule
