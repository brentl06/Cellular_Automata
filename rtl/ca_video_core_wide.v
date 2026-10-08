// ============================================================================
// ca_video_core_wide.v
//
// Board-level core for the 32-lane engine: a 640x480 cellular automaton in
// block RAM, shown on VGA at one pixel per cell and streamed over UART.
//
// ONE CLOCK, TWO RATES
//   Everything runs on a single fast clock (100 MHz on the board). The VGA
//   timing generator advances one pixel every CE_DIV cycles (4 -> 25 MHz
//   pixels), while the engine runs at the full clock rate. That gives the
//   engine 4x the throughput it would have on the pixel clock, with no second
//   clock domain and no clock-domain-crossing logic.
//
// DISPLAY
//   Each pixel lasts CE_DIV cycles. The display address is registered (one
//   cycle) and the BRAM read takes MEM_LAT more, so it settles within the
//   same pixel as long as CE_DIV > MEM_LAT + 1. Registering the address took
//   the v_count -> multiply -> BRAM ADDRB path (the post-route critical path
//   at 100 MHz) off the critical path.
//   Syncs, active, and color are all registered together on the pixel strobe,
//   so they stay aligned (the whole picture is delayed by one pixel).
//   The buffer shown is latched at the start of each frame (disp_sel), and a
//   generation always finishes within the frame it starts in, so every frame
//   shows exactly one complete generation -- no tearing.
//
// BOOT
//   Fills buffer 0 with random words from a xorshift32 generator. The seed
//   comes from a free-running counter, so each reset gives a different
//   pattern; SEED != 0 fixes it (used by the testbenches).
//
// UART
//   Streams a WIN_W x WIN_H window of the grid, one '0'/'1' per cell in
//   row-major order, then '\n' -- the same format as the 1-lane design, so
//   capture_uart.py / make_gif.py work unchanged (pass the window size).
//   On each completed generation (if the UART is idle), the window is first
//   copied into a small local buffer while the engine is idle, then streamed
//   from that copy. The engine never waits on the slow serial link unless
//   capture_mode is set:
//     capture_mode = 0: generations run every frame; the UART streams
//                       whichever generation it can catch.
//     capture_mode = 1: the next generation waits for the UART, so every
//                       generation is streamed (consecutive GIF frames).
//
// CONSTRAINTS
//   P a power of 2, 2..32, dividing WIDTH. WIN_X0 and WIN_W multiples of P.
//   BLOCK a power of 2. CE_DIV > MEM_LAT + 1. MEM_LAT = 1 or 2.
//   One generation must finish within one frame (true by a wide margin at
//   640x480: ~10,600 cycles against ~1.68M per frame).
// ============================================================================

module ca_video_core_wide #(
    parameter WIDTH   = 640,
    parameter HEIGHT  = 480,
    parameter P       = 32,
    parameter MEM_LAT = 2,
    parameter BLOCK   = 1,
    parameter CE_DIV  = 4,

    parameter H_ACTIVE = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48,
    parameter V_ACTIVE = 480, V_FRONT = 10, V_SYNC = 2,  V_BACK = 33,

    parameter FRAMES_PER_GEN = 1,

    parameter WIN_X0 = 288,       // UART window: centered 64x48 by default
    parameter WIN_Y0 = 216,
    parameter WIN_W  = 64,
    parameter WIN_H  = 48,

    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 460800,
    parameter SEED   = 0,

    localparam WORDS  = WIDTH / P,
    localparam NWORD  = HEIGHT * WORDS,
    localparam ADDR_W = (NWORD > 1) ? $clog2(NWORD) : 1
) (
    input  wire        clk,
    input  wire        rst,             // sync, active high
    input  wire [17:0] rule,
    input  wire        capture_mode,

    output wire        hsync,           // active low
    output wire        vsync,           // active low
    output wire        video_active_out,
    output wire        pixel_on,
    output wire        frame_tick,      // 1-cycle pulse at the start of each frame
    output wire        uart_tx_pin,
    output wire        gen_start,       // 1-cycle pulse: a generation begins
    output wire        gen_done         // 1-cycle pulse: that generation is complete
);

    localparam BLOCK_SHIFT = $clog2(BLOCK);
    localparam PH_W        = $clog2(CE_DIV);
    localparam WWPR        = WIN_W / P;               // window words per row
    localparam WIN_WORDS   = WIN_H * WWPR;
    localparam WX0W        = WIN_X0 / P;              // window x offset, in words
    localparam WIN_CELLS   = WIN_W * WIN_H;
    localparam SI_W        = $clog2(WIN_WORDS + 1);
    localparam CI_W        = $clog2(WIN_CELLS);
    localparam WR_W        = (WIN_H > 1) ? $clog2(WIN_H) : 1;
    localparam WW_W        = (WWPR  > 1) ? $clog2(WWPR)  : 1;

    // ------------------------------------------------------------------
    // declarations shared across blocks
    // ------------------------------------------------------------------
    wire              ca_busy, ca_done, cur_buf;
    reg               ca_start;
    wire [P-1:0]      cur_word, disp_word;
    wire              aux_sel;
    wire [ADDR_W-1:0] aux_addr;
    reg               disp_sel;

    localparam [1:0] U_IDLE = 2'd0, U_SNAP = 2'd1, U_SEND = 2'd2, U_NL = 2'd3;
    reg  [1:0] ust;
    wire       uart_busy   = (ust != U_IDLE);
    wire       snap_active = (ust == U_SNAP);

    // ------------------------------------------------------------------
    // pixel strobe: ce is high one cycle in every CE_DIV
    // ------------------------------------------------------------------
    reg [PH_W-1:0] ph;
    always @(posedge clk) begin
        if (rst) ph <= 0;
        else     ph <= (ph == CE_DIV-1) ? {PH_W{1'b0}} : ph + 1'b1;
    end
    wire ce = (ph == CE_DIV-1);

    // ------------------------------------------------------------------
    // video timing
    // ------------------------------------------------------------------
    wire [9:0] pixel_x, pixel_y;
    wire       video_active, hsync_i, vsync_i;

    vga_timing_ce #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK)
    ) vtiming (
        .clk          (clk),
        .rst          (rst),
        .ce           (ce),
        .hsync        (hsync_i),
        .vsync        (vsync_i),
        .video_active (video_active),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .frame_start  (frame_tick)
    );

    // ------------------------------------------------------------------
    // boot: fill buffer 0 with random words
    // ------------------------------------------------------------------
    localparam [1:0] S_BOOT = 2'd0, S_DRAIN = 2'd1, S_RUN = 2'd2;

    reg [1:0]         cs_state;
    reg [ADDR_W-1:0]  boot_addr;
    reg               load_en;
    reg [ADDR_W-1:0]  load_addr;
    reg [P-1:0]       load_data;
    reg [31:0]        rng;
    reg [31:0]        free_ctr = 32'd1;       // never reset: varies the seed

    always @(posedge clk) free_ctr <= free_ctr + 1'b1;

    function [31:0] xorshift32;
        input [31:0] x;
        reg   [31:0] y;
        begin
            y = x ^ (x << 13);
            y = y ^ (y >> 17);
            xorshift32 = y ^ (y << 5);
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            cs_state  <= S_BOOT;
            boot_addr <= 0;
            load_en   <= 1'b0;
            load_addr <= 0;
            load_data <= 0;
            rng       <= (SEED != 0) ? SEED : (free_ctr | 32'd1);
        end else begin
            case (cs_state)
                S_BOOT: begin
                    load_en   <= 1'b1;
                    load_addr <= boot_addr;
                    load_data <= rng[P-1:0];
                    rng       <= xorshift32(rng);
                    if (boot_addr == NWORD-1)
                        cs_state <= S_DRAIN;           // last write lands next cycle
                    else
                        boot_addr <= boot_addr + 1'b1;
                end
                S_DRAIN: begin
                    load_en  <= 1'b0;
                    cs_state <= S_RUN;
                end
                default: load_en <= 1'b0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // generation pacing: at most one start per FRAMES_PER_GEN frames,
    // never while the engine is busy or the UART is copying its window,
    // and (in capture mode) only once the UART has finished streaming
    // ------------------------------------------------------------------
    reg [$clog2(FRAMES_PER_GEN+1)-1:0] frame_count;

    wire can_start = (cs_state == S_RUN) && !ca_busy && !ca_done && !snap_active &&
                     (!capture_mode || !uart_busy);

    always @(posedge clk) begin
        if (rst) begin
            frame_count <= 0;
            ca_start    <= 1'b0;
        end else begin
            ca_start <= 1'b0;
            if (frame_tick && can_start) begin
                if (frame_count == FRAMES_PER_GEN-1) begin
                    frame_count <= 0;
                    ca_start    <= 1'b1;
                end else begin
                    frame_count <= frame_count + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // state buffers + engine
    // ------------------------------------------------------------------
    wire [9:0]        cell_x    = pixel_x >> BLOCK_SHIFT;
    wire [9:0]        cell_y    = pixel_y >> BLOCK_SHIFT;
    wire [ADDR_W-1:0] disp_addr_c = cell_y * WORDS + cell_x / P;

    // registered: the address reaches the BRAM one cycle after the pixel
    // counters change, leaving the multiply its own clock cycle
    reg  [ADDR_W-1:0] disp_addr;
    always @(posedge clk) disp_addr <= disp_addr_c;

`ifndef SYNTHESIS
    initial if (CE_DIV <= MEM_LAT + 1) begin
        $display("ca_video_core_wide: CE_DIV (%0d) must be > MEM_LAT + 1 (%0d)",
                 CE_DIV, MEM_LAT + 1);
        $finish;
    end
`endif

    ca_double_buffer_wide #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .P(P), .MEM_LAT(MEM_LAT), .N_GENS(1)
    ) statebuf (
        .clk       (clk),
        .rst       (rst),
        .start     (ca_start),
        .rule      (rule),
        .busy      (ca_busy),
        .done      (ca_done),
        .cur_buf   (cur_buf),
        .load_en   (load_en),
        .load_addr (load_addr),
        .load_data (load_data),
        .aux_sel   (aux_sel),
        .aux_addr  (aux_addr),
        .cur_word  (cur_word),
        .disp_addr (disp_addr),
        .disp_sel  (disp_sel),
        .disp_word (disp_word)
    );

    // ------------------------------------------------------------------
    // display: latch which buffer to show at the start of each frame, then
    // register syncs, active and color together on the pixel strobe.
    // disp_addr is registered one cycle after the pixel counters change, and
    // the read takes MEM_LAT more; CE_DIV > MEM_LAT + 1 means it has settled
    // by the next strobe.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)             disp_sel <= 1'b0;
        else if (frame_tick) disp_sel <= cur_buf;
    end

    wire disp_bit = disp_word[cell_x % P];

    reg hs_q, vs_q, act_q, pix_q;
    always @(posedge clk) begin
        if (rst) begin
            hs_q  <= 1'b1;
            vs_q  <= 1'b1;
            act_q <= 1'b0;
            pix_q <= 1'b0;
        end else if (ce) begin
            hs_q  <= hsync_i;
            vs_q  <= vsync_i;
            act_q <= video_active;
            pix_q <= video_active && disp_bit;
        end
    end

    assign gen_start        = ca_start;
    assign gen_done         = ca_done;

    assign hsync            = hs_q;
    assign vsync            = vs_q;
    assign video_active_out = act_q;
    assign pixel_on         = pix_q;

    // ------------------------------------------------------------------
    // UART window: snapshot, then stream
    // ------------------------------------------------------------------
    reg [SI_W-1:0] si;                  // snapshot words issued
    reg [WR_W-1:0] sr;                  // window row of next issue
    reg [WW_W-1:0] sw;                  // word within that row
    wire           issue = snap_active && (si < WIN_WORDS);

    assign aux_sel  = snap_active;
    assign aux_addr = (WIN_Y0 + sr) * WORDS + WX0W + sw;

    // read pipeline: an address issued now returns MEM_LAT cycles later
    reg [MEM_LAT-1:0] pv;
    reg [SI_W-1:0]    pidx [0:MEM_LAT-1];
    reg [P-1:0]       snap [0:WIN_WORDS-1];
    integer ka, kb;                     // one loop variable per always block

    always @(posedge clk) begin
        pidx[0] <= si;
        for (ka = 1; ka < MEM_LAT; ka = ka + 1)
            pidx[ka] <= pidx[ka-1];
        if (pv[MEM_LAT-1])
            snap[pidx[MEM_LAT-1]] <= cur_word;
    end

    reg [CI_W-1:0] ci;                  // cell being streamed
    reg [7:0]      uart_byte;
    reg            uart_valid;
    wire           uart_ready;
    wire [P-1:0]   sword = snap[ci / P];
    wire           sbit  = sword[ci % P];

    always @(posedge clk) begin
        if (rst) begin
            ust        <= U_IDLE;
            si         <= 0;
            sr         <= 0;
            sw         <= 0;
            pv         <= 0;
            ci         <= 0;
            uart_byte  <= 8'd0;
            uart_valid <= 1'b0;
        end else begin
            uart_valid <= 1'b0;

            pv[0] <= issue;
            for (kb = 1; kb < MEM_LAT; kb = kb + 1)
                pv[kb] <= pv[kb-1];

            case (ust)
                U_IDLE:
                    if (ca_done) begin               // engine idle: copy the window
                        ust <= U_SNAP;
                        si  <= 0;
                        sr  <= 0;
                        sw  <= 0;
                    end

                U_SNAP: begin
                    if (issue) begin
                        si <= si + 1'b1;
                        if (sw == WWPR-1) begin
                            sw <= 0;
                            sr <= sr + 1'b1;
                        end else begin
                            sw <= sw + 1'b1;
                        end
                    end
                    if (pv[MEM_LAT-1] && pidx[MEM_LAT-1] == WIN_WORDS-1) begin
                        ust <= U_SEND;               // last word captured
                        ci  <= 0;
                    end
                end

                U_SEND:
                    if (uart_ready && !uart_valid) begin
                        uart_byte  <= sbit ? "1" : "0";
                        uart_valid <= 1'b1;
                        if (ci == WIN_CELLS-1)
                            ust <= U_NL;
                        else
                            ci <= ci + 1'b1;
                    end

                U_NL:
                    if (uart_ready && !uart_valid) begin
                        uart_byte  <= 8'h0A;
                        uart_valid <= 1'b1;
                        ust        <= U_IDLE;
                    end
            endcase
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) streamer (
        .clk   (clk),
        .rst   (rst),
        .data  (uart_byte),
        .valid (uart_valid),
        .ready (uart_ready),
        .tx    (uart_tx_pin)
    );

endmodule
