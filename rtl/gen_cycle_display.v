// ============================================================================
// gen_cycle_display.v
//
// Measures how many clock cycles each generation takes on the board and
// shows the most recent value, in decimal, on the Nexys A7's 8-digit
// 7-segment display.
//
// MEASUREMENT
//   cycles = (cycle `done` pulses) - (cycle `start` pulses), i.e. the full
//   wall time of one generation including the double buffer's few cycles of
//   control overhead. Pacing (waiting for frame_tick or the UART) happens
//   before `start`, so it is never counted: the number is the same with SW15
//   on or off. Saturates at 99,999,999 (8 digits).
//
// CONVERSION
//   Binary -> BCD by sequential double dabble, one bit per cycle (32 cycles
//   per measurement), so no wide combinational divider.
//
// DISPLAY
//   Multiplexed, one digit lit at a time for 2^SCAN_BITS cycles
//   (17 -> 1.3 ms per digit, ~95 Hz refresh at 100 MHz). Leading zeros are
//   blanked. Shows 0 until the first generation completes.
//   Segments and anodes are active low, as on the board.
//   seg = {g, f, e, d, c, b, a}  (seg[0] = CA ... seg[6] = CG)
// ============================================================================

module gen_cycle_display #(
    parameter SCAN_BITS = 17
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,      // 1-cycle pulse: generation begins
    input  wire       done,       // 1-cycle pulse: generation complete
    output reg  [7:0] an,         // digit enables, active low (an[0] = rightmost)
    output reg  [6:0] seg,        // segments, active low
    output wire       dp          // decimal point, active low (always off)
);

    localparam [31:0] MAX_SHOWN = 32'd99_999_999;

    // ------------------------------------------------------------------
    // cycle counter
    // ------------------------------------------------------------------
    reg        running;
    reg [31:0] cnt;
    reg [31:0] measured;
    reg        meas_valid;

    always @(posedge clk) begin
        if (rst) begin
            running    <= 1'b0;
            cnt        <= 32'd0;
            measured   <= 32'd0;
            meas_valid <= 1'b0;
        end else begin
            meas_valid <= 1'b0;
            if (start) begin
                running <= 1'b1;
                cnt     <= 32'd1;        // one cycle has elapsed by the next edge
            end else if (running) begin
                if (done) begin
                    running    <= 1'b0;
                    measured   <= cnt;
                    meas_valid <= 1'b1;
                end else if (cnt != 32'hFFFF_FFFF) begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // binary -> BCD (sequential double dabble)
    // ------------------------------------------------------------------
    reg [31:0] bin_sr;
    reg [31:0] bcd_sr;
    reg [5:0]  steps;           // shifts remaining; 0 = idle
    reg [31:0] digits;          // 8 BCD digits currently shown

    // add 3 to every BCD nibble that is >= 5 before shifting
    reg [31:0] bcd_adj;
    integer k;
    always @(*) begin
        for (k = 0; k < 8; k = k + 1)
            bcd_adj[4*k +: 4] = (bcd_sr[4*k +: 4] >= 4'd5) ? bcd_sr[4*k +: 4] + 4'd3
                                                            : bcd_sr[4*k +: 4];
    end

    always @(posedge clk) begin
        if (rst) begin
            bin_sr <= 32'd0;
            bcd_sr <= 32'd0;
            steps  <= 6'd0;
            digits <= 32'd0;
        end else if (meas_valid) begin
            bin_sr <= (measured > MAX_SHOWN) ? MAX_SHOWN : measured;
            bcd_sr <= 32'd0;
            steps  <= 6'd32;
        end else if (steps != 0) begin
            {bcd_sr, bin_sr} <= {bcd_adj, bin_sr} << 1;
            steps <= steps - 1'b1;
            if (steps == 1)
                digits <= {bcd_adj[30:0], bin_sr[31]};   // the final shift
        end
    end

    // ------------------------------------------------------------------
    // display multiplexing
    // ------------------------------------------------------------------
    reg [SCAN_BITS+2:0] scan;
    always @(posedge clk) begin
        if (rst) scan <= 0;
        else     scan <= scan + 1'b1;
    end
    wire [2:0] sel = scan[SCAN_BITS+2:SCAN_BITS];

    // blank[i]: digit i and every digit above it are zero (digit 0 never blanks)
    reg [7:0] blank;
    integer j;
    always @(*) begin
        blank[7] = (digits[31:28] == 4'd0);
        for (j = 6; j >= 1; j = j - 1)
            blank[j] = blank[j+1] && (digits[4*j +: 4] == 4'd0);
        blank[0] = 1'b0;
    end

    wire [3:0] cur_digit = digits[4*sel +: 4];

    reg [6:0] seg_on;           // active high, {g,f,e,d,c,b,a}
    always @(*) begin
        case (cur_digit)
            4'd0: seg_on = 7'b0111111;
            4'd1: seg_on = 7'b0000110;
            4'd2: seg_on = 7'b1011011;
            4'd3: seg_on = 7'b1001111;
            4'd4: seg_on = 7'b1100110;
            4'd5: seg_on = 7'b1101101;
            4'd6: seg_on = 7'b1111101;
            4'd7: seg_on = 7'b0000111;
            4'd8: seg_on = 7'b1111111;
            4'd9: seg_on = 7'b1101111;
            default: seg_on = 7'b1000000;   // '-' (not reachable)
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            an  <= 8'hFF;
            seg <= 7'h7F;
        end else begin
            an  <= ~(8'd1 << sel);
            seg <= blank[sel] ? 7'h7F : ~seg_on;
        end
    end

    assign dp = 1'b1;

endmodule
