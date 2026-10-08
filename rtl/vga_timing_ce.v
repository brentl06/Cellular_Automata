// ============================================================================
// vga_timing_ce.v
//
// vga_timing.v with a clock enable. Identical counters, sync windows, and
// outputs -- the only difference is that the counters advance only on cycles
// where `ce` is high. That lets the whole design run on one fast system clock
// (e.g. 100 MHz) while pixels still advance at the VGA rate (ce every 4th
// cycle -> 25 MHz), with no second clock domain.
//
// frame_start is still a single-cycle pulse (in the fast clock domain), high
// during the first fast cycle in which the counters read (0,0).
//
// With ce tied high this behaves exactly like vga_timing.v.
// ============================================================================

module vga_timing_ce #(
    parameter H_ACTIVE = 640,
    parameter H_FRONT  = 16,
    parameter H_SYNC   = 96,
    parameter H_BACK   = 48,
    parameter V_ACTIVE = 480,
    parameter V_FRONT  = 10,
    parameter V_SYNC   = 2,
    parameter V_BACK   = 33
) (
    input  wire        clk,
    input  wire        rst,     // sync, active high
    input  wire        ce,      // advance one pixel on cycles where ce is high

    output wire        hsync,   // active low
    output wire        vsync,   // active low
    output wire        video_active,
    output wire [9:0]  pixel_x, // valid 0..H_ACTIVE-1 while video_active
    output wire [9:0]  pixel_y, // valid 0..V_ACTIVE-1 while video_active
    output reg         frame_start
);

    localparam H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

    reg [9:0] h_count;
    reg [9:0] v_count;

    always @(posedge clk) begin
        if (rst) begin
            h_count <= 0;
            v_count <= 0;
        end else if (ce) begin
            if (h_count == H_TOTAL-1) begin
                h_count <= 0;
                v_count <= (v_count == V_TOTAL-1) ? 0 : v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            frame_start <= 1'b0;
        else
            frame_start <= ce && (h_count == H_TOTAL-1) && (v_count == V_TOTAL-1);
    end

    assign video_active = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);
    assign pixel_x = (h_count < H_ACTIVE) ? h_count : 10'd0;
    assign pixel_y = (v_count < V_ACTIVE) ? v_count : 10'd0;

    assign hsync = ~((h_count >= H_ACTIVE + H_FRONT) &&
                      (h_count <  H_ACTIVE + H_FRONT + H_SYNC));

    assign vsync = ~((v_count >= V_ACTIVE + V_FRONT) &&
                      (v_count <  V_ACTIVE + V_FRONT + V_SYNC));

endmodule
