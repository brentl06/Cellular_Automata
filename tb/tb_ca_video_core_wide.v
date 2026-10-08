// ============================================================================
// tb_ca_video_core_wide.v
//
// Self-checking testbench for ca_video_core_wide (the full board core: wide
// engine, BRAM double buffer, VGA output, UART window streamer). It checks
// the core from its OUTPUT PINS, against an independent reference:
//
//   * the initial grid is rebuilt from the test SEED, so a boot loader that
//     drops or misplaces a word fails
//   * every pixel's screen position is derived from frame_tick and the pixel
//     strobe timing -- not from the DUT's own counters -- so a shifted or
//     transposed picture fails (Life itself is shift/transpose symmetric, so
//     comparing against the DUT's own coordinates would miss those)
//   * hsync / vsync / active are checked at every pixel
//   * every frame must equal exactly one reference generation, advancing by
//     0 or 1 per frame: no tearing, no skipped generations
//   * the UART line is decoded bit by bit; in capture mode, line i must be
//     the window of generation i+1 (every generation streamed); after
//     switching capture off, lines must show strictly later generations and
//     the display must advance every frame
//
// Two configurations (8 lanes with MEM_LAT=2, and 4 lanes with MEM_LAT=1 and
// 2x2-pixel cells), four rules each (Life, Gnarl, Seeds, and an arbitrary
// rule that includes birth on 0 neighbors).
//
// Vivado: add as a simulation source, Set as Top, Run Behavioral Simulation,
// then `run all` in the Tcl console. Look for ALL CONFIGURATIONS PASSED.
// ============================================================================

`timescale 1ns/1ps

module ca_video_checker #(
    parameter W   = 32, parameter H  = 8,  parameter P  = 8,
    parameter ML  = 2,  parameter BLK = 1, parameter CED = 4,
    parameter HA  = 32, parameter HF = 2,  parameter HS = 4, parameter HB = 2,
    parameter VA  = 8,  parameter VF = 1,  parameter VS = 1, parameter VB = 2,
    parameter WX  = 8,  parameter WY = 2,  parameter WW = 16, parameter WH = 4,
    parameter DIV = 8,
    parameter SEED  = 305419896,
    parameter NCAP  = 5,           // UART lines to check in capture mode
    parameter NFREE = 10           // frames to check after capture is switched off
) (
    input  wire        clk,
    output reg         finished,
    output reg  [31:0] errors
);

    localparam WORDS  = W / P;
    localparam NWORD  = H * WORDS;
    localparam NCELL  = W * H;
    localparam HT     = HA + HF + HS + HB;
    localparam VT     = VA + VF + VS + VB;
    localparam BS     = $clog2(BLK);
    localparam WCELLS = WW * WH;
    localparam MAXG   = 64;        // reference generations kept
    localparam NRULES = 4;
    localparam LIMIT  = 300000;    // cycles per rule before giving up

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg         rst, capture_mode;
    reg  [17:0] rule;
    wire        hsync, vsync, act_o, pix_o, ft, txp;

    ca_video_core_wide #(
        .WIDTH(W), .HEIGHT(H), .P(P), .MEM_LAT(ML), .BLOCK(BLK), .CE_DIV(CED),
        .H_ACTIVE(HA), .H_FRONT(HF), .H_SYNC(HS), .H_BACK(HB),
        .V_ACTIVE(VA), .V_FRONT(VF), .V_SYNC(VS), .V_BACK(VB),
        .WIN_X0(WX), .WIN_Y0(WY), .WIN_W(WW), .WIN_H(WH),
        .CLK_HZ(DIV), .BAUD(1), .SEED(SEED)
    ) dut (
        .clk              (clk),
        .rst              (rst),
        .rule             (rule),
        .capture_mode     (capture_mode),
        .hsync            (hsync),
        .vsync            (vsync),
        .video_active_out (act_o),
        .pixel_on         (pix_o),
        .frame_tick       (ft),
        .uart_tx_pin      (txp)
    );

    // ------------------------------------------------------------------
    // independent reference: generation history built from the seed
    // ------------------------------------------------------------------
    reg        ref_hist [0:MAXG*NCELL-1];
    integer    ref_count;
    reg [17:0] cur_rule;

    function [31:0] xs32;
        input [31:0] x;
        reg   [31:0] y;
        begin
            y = x ^ (x << 13);
            y = y ^ (y >> 17);
            xs32 = y ^ (y << 5);
        end
    endfunction

    task automatic build_gen0;
        integer k, b;
        reg [31:0] r;
        begin
            r = SEED;
            for (k = 0; k < NWORD; k = k + 1) begin
                for (b = 0; b < P; b = b + 1)
                    ref_hist[(k / WORDS) * W + (k % WORDS) * P + b] = r[b];
                r = xs32(r);
            end
            ref_count = 1;
        end
    endtask

    task automatic need(input integer g);          // compute up to generation g
        integer rr, c, dr, dc, s, base, nb;
        begin
            while (ref_count <= g && ref_count < MAXG) begin
                base = (ref_count - 1) * NCELL;
                nb   = ref_count * NCELL;
                for (rr = 0; rr < H; rr = rr + 1)
                    for (c = 0; c < W; c = c + 1) begin
                        s = 0;
                        for (dr = -1; dr <= 1; dr = dr + 1)
                            for (dc = -1; dc <= 1; dc = dc + 1)
                                if (dr != 0 || dc != 0)
                                    s = s + ref_hist[base + ((rr+dr+H)%H)*W + ((c+dc+W)%W)];
                        ref_hist[nb + rr*W + c] = ref_hist[base + rr*W + c] ? cur_rule[9+s]
                                                                             : cur_rule[s];
                    end
                ref_count = ref_count + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // tracking state
    // ------------------------------------------------------------------
    reg  [1:0] cellv    [0:NCELL-1];   // 2 = not seen yet this frame
    reg  [7:0] line_buf [0:WCELLS-1];

    integer n, n0, kpix, koff, hh, vv, ci, i, g, found;
    integer g_disp, frames, free_frames, free_adv;
    integer rx_state, rx_start, rx_byte, line_len, lines, last_g, run_err;
    reg     tracking, capture, prev_tx;
    reg     hs_e, vs_e, act_e, same, nxt, complete;

    task automatic report(input [8*56-1:0] msg);
        begin
            if (run_err < 8)
                $display("  [W%0d P%0d L%0d] rule %05h: %0s (cycle %0d)", W, P, ML, cur_rule, msg, n);
            run_err = run_err + 1;
        end
    endtask

    function frame_eq(input integer gen);
        integer j;
        reg ok;
        begin
            ok = 1'b1;
            for (j = 0; j < NCELL; j = j + 1)
                if (cellv[j] != {1'b0, ref_hist[gen*NCELL + j]}) ok = 1'b0;
            frame_eq = ok;
        end
    endfunction

    function line_eq(input integer gen);
        integer r, c;
        reg ok;
        begin
            ok = 1'b1;
            for (r = 0; r < WH; r = r + 1)
                for (c = 0; c < WW; c = c + 1)
                    if (line_buf[r*WW + c] != (ref_hist[gen*NCELL + (WY+r)*W + WX + c] ? 8'h31 : 8'h30))
                        ok = 1'b0;
            line_eq = ok;
        end
    endfunction

    // ------------------------------------------------------------------
    // monitor: sample every output just after each clock edge
    // ------------------------------------------------------------------
    initial begin n = 0; tracking = 1'b0; end

    always @(posedge clk) begin
        #1;
        n = n + 1;
        if (tracking) begin
            // ---- display: one pixel per strobe after frame_tick ----
            if (n0 >= 0 && n > n0 && ((n - n0) % CED) == 0) begin
                kpix = (n - n0) / CED - 1;
                if (kpix < HT*VT) begin
                    hh    = kpix % HT;
                    vv    = kpix / HT;
                    hs_e  = !(hh >= HA+HF && hh < HA+HF+HS);
                    vs_e  = !(vv >= VA+VF && vv < VA+VF+VS);
                    act_e = (hh < HA) && (vv < VA);
                    if (hsync !== hs_e || vsync !== vs_e || act_o !== act_e)
                        report("sync/active mismatch");
                    if (act_o !== 1'b1 && pix_o === 1'b1)
                        report("pixel lit during blanking");
                    if (act_e) begin
                        ci = (vv >> BS) * W + (hh >> BS);
                        if (pix_o !== 1'b0 && pix_o !== 1'b1)
                            report("pixel is X");
                        else if (cellv[ci] == 2'd2)
                            cellv[ci] = {1'b0, pix_o};
                        else if (cellv[ci] != {1'b0, pix_o})
                            report("pixels within one cell disagree");
                    end
                end
            end

            if (ft === 1'b1) begin
                if (n0 >= 0) begin                         // a full frame just ended
                    complete = 1'b1;
                    for (i = 0; i < NCELL; i = i + 1)
                        if (cellv[i] == 2'd2) complete = 1'b0;
                    if (!complete) report("frame did not cover every cell");
                    if (g_disp + 1 >= MAXG) report("reference history overflow");
                    need(g_disp + 1);
                    // settled patterns can make consecutive generations
                    // identical; free-running mode must advance, so prefer
                    // "next" there, and "same" in capture mode
                    same = frame_eq(g_disp);
                    nxt  = frame_eq(g_disp + 1);
                    if (!same && !nxt)
                        report("frame matches neither current nor next gen");
                    else if (nxt && (!capture || !same)) begin
                        g_disp = g_disp + 1;
                        if (!capture) free_adv = free_adv + 1;
                    end
                    frames = frames + 1;
                    if (!capture) free_frames = free_frames + 1;
                end
                n0 = n;
                for (i = 0; i < NCELL; i = i + 1) cellv[i] = 2'd2;
            end

            // ---- UART receiver: sample mid-bit, DIV cycles per bit ----
            if (rx_state == 0) begin
                if (prev_tx && !txp) begin
                    rx_state = 1;
                    rx_start = n;
                    rx_byte  = 0;
                end
            end else begin
                koff = n - rx_start;
                for (i = 0; i < 8; i = i + 1)
                    if (koff == DIV*(i+1) + DIV/2) rx_byte = rx_byte | ((txp ? 1 : 0) << i);
                if (koff == DIV*9 + DIV/2) begin
                    if (!txp) report("bad stop bit");
                    rx_state = 0;
                    if (rx_byte == 10) begin                 // '\n': a full window
                        if (line_len != WCELLS) report("UART line has wrong length");
                        else begin
                            found = -1;
                            for (g = last_g + 1; g <= last_g + 40 && found < 0 && g < MAXG; g = g + 1) begin
                                need(g);
                                if (line_eq(g)) found = g;
                            end
                            if (found < 0) report("UART line matches no later generation");
                            else begin
                                if (capture && found != last_g + 1)
                                    report("capture mode skipped a generation");
                                last_g = found;
                            end
                        end
                        line_len = 0;
                        lines    = lines + 1;
                        if (capture && lines == NCAP) begin
                            capture      = 1'b0;             // switch to free-running
                            capture_mode <= 1'b0;
                        end
                    end else begin
                        if (line_len < WCELLS) line_buf[line_len] = rx_byte[7:0];
                        line_len = line_len + 1;
                    end
                end
            end
            prev_tx = txp;
        end
    end

    // ------------------------------------------------------------------
    // stimulus: for each rule, reset, run capture phase then free phase
    // ------------------------------------------------------------------
    integer ri, ii, waited;

    initial begin
        finished     = 1'b0;
        errors       = 0;
        rst          = 1'b1;
        capture_mode = 1'b1;
        rule         = 18'd0;

        for (ri = 0; ri < NRULES; ri = ri + 1) begin
            case (ri)
                0:       cur_rule = {9'b000001100, 9'b000001000};  // Life  B3/S23
                1:       cur_rule = {9'b000000010, 9'b000000010};  // Gnarl B1/S1
                2:       cur_rule = {9'b000000000, 9'b000000100};  // Seeds B2/S
                default: cur_rule = 18'h2B6D5;                     // arbitrary, incl. B0
            endcase

            tracking = 1'b0;
            rst          <= 1'b1;
            capture_mode <= 1'b1;
            rule         <= cur_rule;
            repeat (8) @(posedge clk);

            build_gen0;
            n0 = -1;  g_disp = 0;  frames = 0;  free_frames = 0;  free_adv = 0;
            capture = 1'b1;  rx_state = 0;  prev_tx = 1'b1;
            line_len = 0;  lines = 0;  last_g = 0;  run_err = 0;
            for (ii = 0; ii < NCELL; ii = ii + 1) cellv[ii] = 2'd2;

            rst <= 1'b0;
            tracking = 1'b1;

            waited = 0;
            while (!(!capture && free_frames >= NFREE) && waited < LIMIT) begin
                @(posedge clk);
                waited = waited + 1;
            end
            tracking = 1'b0;

            if (capture)                report("never finished capture phase");
            if (free_frames < NFREE)    report("never finished free phase");
            if (free_adv < NFREE - 2)   report("free-running display did not advance");

            $display("W=%0d H=%0d P=%0d MEM_LAT=%0d BLOCK=%0d rule %05h: %0d frames, gen %0d, %0d UART lines -- %s",
                     W, H, P, ML, BLK, cur_rule, frames, g_disp, lines, (run_err == 0) ? "ok" : "FAIL");
            errors = errors + run_err;
        end

        $display("W=%0d H=%0d P=%0d MEM_LAT=%0d BLOCK=%0d: %s (%0d errors)",
                 W, H, P, ML, BLK, (errors == 0) ? "PASS" : "FAIL", errors);
        finished = 1'b1;
    end

endmodule


module tb_ca_video_core_wide;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire        fa, fb;
    wire [31:0] ea, eb;

    // 8 lanes, BRAM output register on (MEM_LAT=2), one pixel per cell
    ca_video_checker #(
        .W(32), .H(8), .P(8), .ML(2), .BLK(1), .CED(4),
        .HA(32), .HF(2), .HS(4), .HB(2), .VA(8), .VF(1), .VS(1), .VB(2),
        .WX(8), .WY(2), .WW(16), .WH(4), .DIV(8), .SEED(305419896)
    ) cfg_a (clk, fa, ea);

    // 4 lanes, plain BRAM read (MEM_LAT=1), 2x2 pixels per cell
    ca_video_checker #(
        .W(16), .H(6), .P(4), .ML(1), .BLK(2), .CED(4),
        .HA(32), .HF(2), .HS(4), .HB(2), .VA(12), .VF(1), .VS(1), .VB(2),
        .WX(4), .WY(1), .WW(8), .WH(3), .DIV(8), .SEED(1640531527)
    ) cfg_b (clk, fb, eb);

    initial begin
        wait (fa && fb);
        if (ea + eb == 0) $display("ALL CONFIGURATIONS PASSED");
        else              $display("FAILED: %0d total errors", ea + eb);
        $finish;
    end

endmodule
