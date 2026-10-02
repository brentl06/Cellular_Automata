// ============================================================================
// tb_ca_update_engine_wide.v
//
// Self-checking testbench for ca_update_engine_wide. Six configurations run in
// parallel, each against an independent bit-level reference model written
// directly from the rule definition (no shared logic with the RTL):
//
//   W=16 H=8  P=4   MEM_LAT=1   main case, 4 words per row
//   W=16 H=8  P=1   MEM_LAT=1   1-lane build must still be correct
//   W=16 H=8  P=16  MEM_LAT=1   whole row in one word (WORDS=1 edge case)
//   W=24 H=5  P=8   MEM_LAT=1   non-power-of-2 row, odd height
//   W=16 H=8  P=4   MEM_LAT=2   BRAM output register enabled
//   W=64 H=16 P=32  MEM_LAT=2   the real lane count
//
// Each configuration runs 8 rules (Life, HighLife, Seeds, Gnarl, Day & Night,
// plus 3 random 18-bit rules that exercise every table entry) for several
// generations from random seeds, and checks:
//   * every cell against the reference model
//   * every word is written exactly once per generation
//     (the next-state memory is poisoned with X before each generation)
//   * the rule is latched at start: the rule input is scrambled right after
//     `start`, so an engine reading the live input would fail
//   * back-to-back generations: the next `start` follows `done` as closely as
//     the ping-pong allows
//
// Run:
//   iverilog -g2012 -o simwide tb_ca_update_engine_wide.v ../rtl/ca_update_engine_wide.v
//   vvp simwide
// In Vivado/XSim, set this as the simulation top and use `run all` (the
// default 1000 ns run is far too short).
//
// The testbench memory model supports MEM_LAT = 1 or 2.
// ============================================================================

`timescale 1ns/1ps

module ca_wide_checker #(
    parameter W       = 16,
    parameter H       = 8,
    parameter P       = 4,
    parameter MEM_LAT = 1,
    parameter GENS    = 6,
    parameter SEED    = 1
) (
    input  wire        clk,
    output reg         finished,
    output reg  [31:0] errors
);

    localparam WORDS  = W / P;
    localparam NWORD  = H * WORDS;
    localparam NCELL  = W * H;
    localparam ADDR_W = (NWORD > 1) ? $clog2(NWORD) : 1;
    localparam NRULES = 8;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg                rst, start;
    reg  [17:0]        rule;
    wire               busy, done, wr_en;
    wire [ADDR_W-1:0]  rd_addr, wr_addr;
    wire [P-1:0]       rd_data, wr_data;

    ca_update_engine_wide #(.WIDTH(W), .HEIGHT(H), .P(P), .MEM_LAT(MEM_LAT)) dut (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .rule    (rule),
        .busy    (busy),
        .done    (done),
        .rd_addr (rd_addr),
        .rd_data (rd_data),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .wr_en   (wr_en)
    );

    // ------------------------------------------------------------------
    // word-wide state memories with a MEM_LAT-cycle registered read
    // ------------------------------------------------------------------
    reg [P-1:0] cur_mem [0:NWORD-1];
    reg [P-1:0] nxt_mem [0:NWORD-1];
    reg [P-1:0] rq1, rq2;
    integer     wcount  [0:NWORD-1];

    assign rd_data = (MEM_LAT == 2) ? rq2 : rq1;

    always @(posedge clk) begin
        rq1 <= cur_mem[rd_addr];
        rq2 <= rq1;
        if (wr_en) begin
            nxt_mem[wr_addr] <= wr_data;
            wcount[wr_addr]  <= wcount[wr_addr] + 1;
        end
    end

    // ------------------------------------------------------------------
    // independent reference model: flat cell array, rule applied literally
    // ------------------------------------------------------------------
    reg ref_cur [0:NCELL-1];
    reg ref_nxt [0:NCELL-1];

    task automatic ref_step(input [17:0] rl);
        integer r, c, dr, dc, s;
        begin
            for (r = 0; r < H; r = r + 1)
                for (c = 0; c < W; c = c + 1) begin
                    s = 0;
                    for (dr = -1; dr <= 1; dr = dr + 1)
                        for (dc = -1; dc <= 1; dc = dc + 1)
                            if (dr != 0 || dc != 0)
                                s = s + ref_cur[((r+dr+H)%H)*W + ((c+dc+W)%W)];
                    ref_nxt[r*W+c] = ref_cur[r*W+c] ? rl[9+s] : rl[s];
                end
            for (r = 0; r < NCELL; r = r + 1)
                ref_cur[r] = ref_nxt[r];
        end
    endtask

    // pack the reference grid into the DUT's word layout: cell (r,c) is
    // word r*WORDS + c/P, bit c%P
    task automatic load_mem;
        integer r, wi, b;
        reg [P-1:0] wv;
        begin
            for (r = 0; r < H; r = r + 1)
                for (wi = 0; wi < WORDS; wi = wi + 1) begin
                    for (b = 0; b < P; b = b + 1)
                        wv[b] = ref_cur[r*W + wi*P + b];
                    cur_mem[r*WORDS + wi] = wv;
                end
        end
    endtask

    task automatic check_gen(input integer ri, input integer g);
        integer a, b, e;
        reg [P-1:0] got, want;
        begin
            e = 0;
            for (a = 0; a < NWORD; a = a + 1) begin
                got = nxt_mem[a];
                for (b = 0; b < P; b = b + 1)
                    want[b] = ref_cur[(a / WORDS)*W + (a % WORDS)*P + b];
                if (wcount[a] != 1) begin
                    if (e < 4)
                        $display("[W%0d H%0d P%0d L%0d] rule %0d gen %0d: word %0d written %0d times",
                                 W, H, P, MEM_LAT, ri, g, a, wcount[a]);
                    e = e + 1;
                end else if (got !== want) begin
                    if (e < 4)
                        $display("[W%0d H%0d P%0d L%0d] rule %0d gen %0d: word %0d got %h want %h",
                                 W, H, P, MEM_LAT, ri, g, a, got, want);
                    e = e + 1;
                end
            end
            errors = errors + e;
        end
    endtask

    // ------------------------------------------------------------------
    // stimulus
    // ------------------------------------------------------------------
    integer    seed, ri, g, i, guard;
    reg [17:0] cur_rule;

    initial begin
        finished = 1'b0;
        errors   = 0;
        seed     = SEED;
        rst      = 1'b1;
        start    = 1'b0;
        rule     = 18'd0;
        for (i = 0; i < NWORD; i = i + 1) wcount[i] = 0;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk); #1;

        for (ri = 0; ri < NRULES; ri = ri + 1) begin
            case (ri)
                0: cur_rule = {9'b000001100, 9'b000001000};   // Life        B3/S23
                1: cur_rule = {9'b000001100, 9'b001001000};   // HighLife    B36/S23
                2: cur_rule = {9'b000000000, 9'b000000100};   // Seeds       B2/S
                3: cur_rule = {9'b000000010, 9'b000000010};   // Gnarl       B1/S1
                4: cur_rule = {9'b111011000, 9'b111001000};   // Day & Night B3678/S34678
                default: cur_rule = $random(seed);            // random 18-bit rule
            endcase

            for (i = 0; i < NCELL; i = i + 1)
                ref_cur[i] = (($random(seed) & 7) < 3);      // ~37% density
            load_mem;

            for (g = 0; g < GENS; g = g + 1) begin
                for (i = 0; i < NWORD; i = i + 1) begin
                    nxt_mem[i] = {P{1'bx}};                   // poison
                    wcount[i]  = 0;
                end

                // non-blocking stimulus: no race with the DUT's own sampling
                rule  <= cur_rule;
                start <= 1'b1;
                @(posedge clk);
                start <= 1'b0;
                rule  <= $random(seed);                       // must be ignored

                guard = 0;
                @(posedge clk); #1;
                while (done !== 1'b1) begin
                    @(posedge clk); #1;
                    guard = guard + 1;
                    if (guard > 50*NWORD + 10000) begin
                        $display("[W%0d H%0d P%0d L%0d] TIMEOUT: rule %0d gen %0d never finished",
                                 W, H, P, MEM_LAT, ri, g);
                        $finish;
                    end
                end
                @(posedge clk); #1;                           // final write lands here

                ref_step(cur_rule);
                check_gen(ri, g);

                for (i = 0; i < NWORD; i = i + 1)
                    cur_mem[i] = nxt_mem[i];                  // ping-pong
            end
        end

        $display("W=%0d H=%0d P=%0d MEM_LAT=%0d: %0d rules x %0d gens -- %s (%0d errors)",
                 W, H, P, MEM_LAT, NRULES, GENS, (errors == 0) ? "PASS" : "FAIL", errors);
        finished = 1'b1;
    end

endmodule


module tb_ca_update_engine_wide;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire        f0, f1, f2, f3, f4, f5;
    wire [31:0] e0, e1, e2, e3, e4, e5;

    ca_wide_checker #(.W(16), .H(8),  .P(4),  .MEM_LAT(1), .GENS(6), .SEED(11)) c0 (clk, f0, e0);
    ca_wide_checker #(.W(16), .H(8),  .P(1),  .MEM_LAT(1), .GENS(6), .SEED(22)) c1 (clk, f1, e1);
    ca_wide_checker #(.W(16), .H(8),  .P(16), .MEM_LAT(1), .GENS(6), .SEED(33)) c2 (clk, f2, e2);
    ca_wide_checker #(.W(24), .H(5),  .P(8),  .MEM_LAT(1), .GENS(6), .SEED(44)) c3 (clk, f3, e3);
    ca_wide_checker #(.W(16), .H(8),  .P(4),  .MEM_LAT(2), .GENS(6), .SEED(55)) c4 (clk, f4, e4);
    ca_wide_checker #(.W(64), .H(16), .P(32), .MEM_LAT(2), .GENS(4), .SEED(66)) c5 (clk, f5, e5);

    initial begin
        wait (f0 && f1 && f2 && f3 && f4 && f5);
        if ((e0 + e1 + e2 + e3 + e4 + e5) == 0)
            $display("ALL CONFIGURATIONS PASSED");
        else
            $display("FAILED: %0d total errors", e0 + e1 + e2 + e3 + e4 + e5);
        $finish;
    end

endmodule
