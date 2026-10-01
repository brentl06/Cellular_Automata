// ============================================================================
// nexys_a7_top_wide.v
//
// Top level for the 32-lane design on the Nexys A7-100T.
//
// CLOCKING
//   Runs directly on the board's 100 MHz oscillator -- no Clocking Wizard.
//   The video core derives 25 MHz pixels internally with a clock enable
//   (one pixel every 4 cycles), which VGA monitors accept for 640x480@60.
//   The engine runs at the full 100 MHz.
//
// CONTROLS
//   SW[3:0]    rule preset (same 16 presets as before)
//   SW15       capture mode: on = every generation is streamed over UART
//              (the display slows to the UART's pace); off = one generation
//              per frame, UART streams whichever generation it can
//   CPU_RESET  reboot with a new random pattern
//
// 7-SEGMENT DISPLAY
//   Clock cycles taken by the most recent generation, in decimal (measured
//   on the board from the engine's start pulse to its done pulse). Cells per
//   clock = 307200 / shown value.
//
// UART
//   460800 baud, 8N1, the same PuTTY setting as before. Streams the 64x48
//   window at the center of the 640x480 grid:
//       python3 make_gif.py <capture file> 64 48
// ============================================================================

module nexys_a7_top_wide #(
    parameter SEG_SCAN_BITS = 17      // 7-seg digit period 2^17 cycles (lowered in simulation)
) (
    input  wire       CLK100MHZ,
    input  wire       CPU_RESETN,     // active low
    input  wire [3:0] SW,             // rule select
    input  wire       SW15,           // capture mode

    output wire [3:0] VGA_R,
    output wire [3:0] VGA_G,
    output wire [3:0] VGA_B,
    output wire       VGA_HS,
    output wire       VGA_VS,
    output wire       UART_RXD_OUT,

    output wire       CA, CB, CC, CD, CE, CF, CG, DP,   // 7-seg, active low
    output wire [7:0] AN
);

    wire clk = CLK100MHZ;

    // ------------------------------------------------------------------
    // reset: power-on reset plus the synchronized CPU_RESET button
    // ------------------------------------------------------------------
    reg [3:0] por = 4'hF;
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk) begin
        por      <= {por[2:0], 1'b0};
        rst_sync <= {rst_sync[0], ~CPU_RESETN};
    end
    wire rst = por[3] | rst_sync[1];

    // ------------------------------------------------------------------
    // switches: 2-FF synchronizer (async to clk)
    // ------------------------------------------------------------------
    reg [4:0] sw_sync0, sw_sync1;
    always @(posedge clk) begin
        sw_sync0 <= {SW15, SW};
        sw_sync1 <= sw_sync0;
    end

    wire capture_mode = sw_sync1[4];

    // {survive[8:0], birth[8:0]}; bit N = "N live neighbors"
    // The engine latches the rule at the start of each generation, so
    // flipping a switch never produces a half-and-half generation.
    reg [17:0] rule;
    always @(*) begin
        case (sw_sync1[3:0])
            4'd0:  rule = {9'b000001100, 9'b000001000}; // Life           B3/S23
            4'd1:  rule = {9'b000001100, 9'b001001000}; // HighLife       B36/S23
            4'd2:  rule = {9'b111011000, 9'b111001000}; // Day & Night    B3678/S34678
            4'd3:  rule = {9'b000000000, 9'b000000100}; // Seeds          B2/S
            4'd4:  rule = {9'b000111110, 9'b000001000}; // Maze           B3/S12345
            4'd5:  rule = {9'b000011110, 9'b000001000}; // Mazectric      B3/S1234
            4'd6:  rule = {9'b010101010, 9'b010101010}; // Replicator     B1357/S1357
            4'd7:  rule = {9'b111111111, 9'b000001000}; // Life w/o Death B3/S012345678
            4'd8:  rule = {9'b000100110, 9'b001001000}; // 2x2            B36/S125
            4'd9:  rule = {9'b000110100, 9'b101001000}; // Move           B368/S245
            4'd10: rule = {9'b111110000, 9'b000001000}; // Coral          B3/S45678
            4'd11: rule = {9'b111101000, 9'b111010000}; // Anneal         B4678/S35678
            4'd12: rule = {9'b111100000, 9'b111101000}; // Diamoeba       B35678/S5678
            4'd13: rule = {9'b000000010, 9'b000000010}; // Gnarl          B1/S1
            4'd14: rule = {9'b011110000, 9'b000111000}; // Assimilation   B345/S4567
            4'd15: rule = {9'b000000000, 9'b000011100}; // Serviettes     B234/S
            default: rule = {9'b000001100, 9'b000001000};
        endcase
    end

    // ------------------------------------------------------------------
    // core: 640x480 grid, 32 lanes, BRAM output register on
    // ------------------------------------------------------------------
    wire hsync, vsync, pixel_on, video_active_out, frame_tick;
    wire gen_start, gen_done;

    ca_video_core_wide #(
        .WIDTH   (640),
        .HEIGHT  (480),
        .P       (32),
        .MEM_LAT (2),
        .CE_DIV  (4),
        .CLK_HZ  (100_000_000),
        .BAUD    (460800)
    ) core (
        .clk              (clk),
        .rst              (rst),
        .rule             (rule),
        .capture_mode     (capture_mode),
        .hsync            (hsync),
        .vsync            (vsync),
        .video_active_out (video_active_out),
        .pixel_on         (pixel_on),
        .frame_tick       (frame_tick),
        .uart_tx_pin      (UART_RXD_OUT),
        .gen_start        (gen_start),
        .gen_done         (gen_done)
    );

    // ------------------------------------------------------------------
    // 7-segment: measured cycles per generation
    // ------------------------------------------------------------------
    wire [6:0] seg;

    gen_cycle_display #(.SCAN_BITS(SEG_SCAN_BITS)) perf (
        .clk   (clk),
        .rst   (rst),
        .start (gen_start),
        .done  (gen_done),
        .an    (AN),
        .seg   (seg),
        .dp    (DP)
    );

    assign {CG, CF, CE, CD, CC, CB, CA} = seg;

    assign VGA_HS = hsync;
    assign VGA_VS = vsync;
    assign VGA_R  = pixel_on ? 4'hF : 4'h0;
    assign VGA_G  = pixel_on ? 4'hF : 4'h0;
    assign VGA_B  = pixel_on ? 4'hF : 4'h0;

endmodule
