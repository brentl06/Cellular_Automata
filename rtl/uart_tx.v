// ============================================================================
// uart_tx.v
//
// Minimal 8N1 UART transmitter. No FIFO, no parity, no flow control -- the
// CA streamer only ever sends one byte at a time and waits for `ready`, so
// buffering would be dead weight.
//
// Handshake: assert `valid` for one cycle while `ready` is high; `data` is
// latched on that cycle. `ready` drops until the stop bit completes.
//
// BAUD ACCURACY
//   DIVISOR truncates, so the real baud rate is CLK_HZ/DIVISOR rather than
//   exactly BAUD. At 25.175MHz / 115200 that's DIVISOR=218, giving 115,482
//   baud -- 0.24% fast. UARTs resync on every start bit and tolerate
//   roughly 2-3% per-character error, so this is comfortably fine. If you
//   retarget to a much lower clock, re-check that margin.
// ============================================================================

module uart_tx #(
    parameter CLK_HZ = 25_175_000,
    parameter BAUD   = 115200,

    localparam integer DIVISOR = CLK_HZ / BAUD,
    localparam integer DIV_W   = $clog2(DIVISOR)
) (
    input  wire       clk,
    input  wire       rst,        // sync, active high

    input  wire [7:0] data,
    input  wire       valid,      // 1-cycle pulse, only honored while ready
    output reg        ready,      // high when idle and able to accept a byte

    output reg        tx          // serial line, idle high
);

    reg [DIV_W-1:0] div_cnt;
    reg [3:0]       bit_idx;      // 0 = start, 1..8 = data, 9 = stop
    reg [7:0]       shifter;
    reg             busy;

    always @(posedge clk) begin
        if (rst) begin
            tx      <= 1'b1;      // idle high
            ready   <= 1'b1;
            busy    <= 1'b0;
            div_cnt <= 0;
            bit_idx <= 4'd0;
            shifter <= 8'd0;
        end else if (!busy) begin
            tx    <= 1'b1;
            ready <= 1'b1;
            if (valid) begin
                shifter <= data;
                busy    <= 1'b1;
                ready   <= 1'b0;
                div_cnt <= 0;
                bit_idx <= 4'd0;
                tx      <= 1'b0;          // start bit
            end
        end else begin
            if (div_cnt == DIVISOR-1) begin
                div_cnt <= 0;
                if (bit_idx == 4'd9) begin
                    busy  <= 1'b0;        // stop bit finished
                    ready <= 1'b1;
                    tx    <= 1'b1;
                end else begin
                    bit_idx <= bit_idx + 1'b1;
                    if (bit_idx == 4'd8) begin
                        tx <= 1'b1;       // stop bit
                    end else begin
                        tx      <= shifter[0];            // LSB first
                        shifter <= {1'b0, shifter[7:1]};
                    end
                end
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

endmodule
