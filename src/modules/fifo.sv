/*
* 4-word 32-bit synchronous FIFO
* Inputs:
    * d_in: 32-bit input word
    * w_en: write enable signal
    * clk: clock input
    * rst: reset input
* Outputs:
    * d_out: 32-bit output word
    * full: signal asserted if the fifo is full
    * empty: signal asserted if the fifo is empty
    * w_ptr: the current position of the write pointer
    * r_ptr: the current position of the read pointer
*/
module fifo #(
    parameter DEPTH=4,
    parameter DATA_WIDTH=32,
    parameter DEPTH_BITS = $clog2(DEPTH))(
    input wire clk,
    input wire rst,
    input wire [DATA_WIDTH-1:0] d_in,
    input wire w_en,
    input wire r_en,
    output reg [DATA_WIDTH-1:0] d_out,
    output reg [DEPTH_BITS:0] wptr,
    output reg [DEPTH_BITS:0] rptr
    );

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg full, empty;
    assign empty = (wptr == rptr);
    assign full = ({~wptr[DEPTH_BITS], wptr[DEPTH_BITS-1:0]} == rptr);

    //write data
    always @ (posedge clk) begin
        if (rst) begin
            wptr <= '0;
            d_out <= '0;
        end else if (w_en & !full) begin
            mem[wptr[DEPTH_BITS-1:0]] <= d_in;
            wptr <= wptr + 1;
        end
    end

    //read data
    always @ (posedge clk) begin
        if (rst) begin
            rptr <= '0;
        end else if (r_en & !empty) begin
            d_out <= mem[rptr[DEPTH_BITS-1:0]];
            rptr <= rptr + 1;
        end
    end

endmodule
