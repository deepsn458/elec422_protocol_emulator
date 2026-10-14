*   w_data[31:0], pull (r_en), push(w_en), w_clk, r_clk, r_rst, w_rst
* Output ports
*   r_data[31:0], full, empty, level[2:0]
*/

module async_fifo #(parameter DEPTH=4, parameter DATA_WIDTH=32) (
    
    parameter DEPTH_BITS = $clog2(DEPTH);

    input wire w_clk,
    input wire r_clk,
    input wire[DATA_WIDTH-1:0] w_data,
    input wire w_en, //push
    input wire r_en, //pull
    input wire r_rst,
    input wire w_rst,
    output wire [DEPTH_BITS:0] b_wptr,
    output wire [DEPTH_BITS:0] b_rptr,
    output wire [DATA_WIDTH-1:0] r_data
);


reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
reg full, empty;

reg [DEPTH_BITS:0] g_wptr_next, g_wptr, g_wptr_sync;
reg [DEPTH_BITS:0] g_rptr_next, g_rptr, g_rptr_sync;
reg [DEPTH_BITS:0] b_wptr_next, b_rptr_next;

/* Main fifo logic */
always @(posedge w_clk) begin
    if (w_en & !full) begin
        mem[b_wptr[DEPTH_BITS-1:0]] <= w_data;
    end
end

assign r_data  = mem[b_rptr[DEPTH_BITS-1:0]];

/* write pointer handler */
wire full_next;

assign full_next = (g_wptr_next == {~g_rptr_sync[DEPTH_BITS:DEPTH_BITS-1], g_rptr_sync[DEPTH_BITS-2:0]});
assign b_wptr_next = (w_en & !full) ? (b_wptr + 1) : b_wptr;
assign g_wptr_next = b_wptr_next ^ (b_wptr_next >> 1);

always @ (posedge w_clk) begin 
    if (w_rst) begin
        b_wptr <= 0;
        full <= 0;
        g_wptr <= 0;
    end else begin
        b_wptr <= b_wptr_next;
        full <= full_next;
        g_wptr <= g_wptr_next;
    end
end

/* read pointer handler */
wire empty_next;
assign empty_next = (g_wptr_sync == g_rptr_next);
assign b_rptr_next = (r_en & !empty) ? (b_rptr+1) : b_rptr;
assign g_rptr_next = b_rptr_next ^ (b_rptr_next >> 1);

always @(posedge r_clk) begin
    if (r_rst) begin
        b_rptr <= 0;
        empty <= 1;
        g_rptr <= 0;
    end else begin
        b_rptr <= b_rptr_next;
        empty <= empty_next;
        g_rptr <= g_rptr_next;
    end
end

/*synchronizers*/
reg [DEPTH_BITS:0] g_wptr_ff;
reg [DEPTH_BITS:0] g_rptr_ff;

always @(posedge w_clk) begin
    if (w_rst) begin
        g_wptr_ff <= 0;
        g_wptr_sync <= 0;
    end else begin
        g_wptr_ff <= g_wptr;
        g_wptr_sync <= g_wptr_ff;
    end
end

always @ (posedge r_clk) begin
    if (r_rst) begin
        g_rptr_ff <= 0;
        g_rptr_sync <= 0;
    end else begin
        g_rptr_ff <= g_rptr;
        g_rptr_sync <= g_rptr_ff;
    end
end

endmodule
