// ============================================================================
// tb_ca_pipeline_engine.v
//
// Self-checking testbench for ca_pipeline_engine (K = STAGES generations per
// pass). Each configuration runs against an independent bit-level reference
// model written straight from the rule definition: dead top/bottom edges
// (cells outside rows 0..H-1 are 0), horizontal wraparound, K generations per
// pass. Checked per pass:
//   * every cell against the reference after K generations
//   * every word written exactly once (next-state memory poisoned with X)
//   * the rule is latched at start (the rule input is scrambled right after)
//   * back-to-back passes
//
// Configurations cover K = 1, 2, 3, 4, 8, 32, every lane count the wide engine
// supports (P = 1 .. 32, including a whole row in one word), both memory
// latencies, and odd/non-power-of-2 sizes.
//
//   iverilog -g2012 -o sim_pipe tb_ca_pipeline_engine.v ca_pipeline_engine.v ca_stage.v && vvp sim_pipe
// ============================================================================

`timescale 1ns/1ps

module ca_pipe_checker #(
    parameter W       = 16,
    parameter H       = 8,
    parameter P       = 4,
    parameter MEM_LAT = 1,
    parameter K       = 2,
    parameter PASSES  = 3,
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
    localparam NRULES = 6;

    reg                rst, start;
    reg  [17:0]        rule;
    wire               busy, done, wr_en;
    wire [ADDR_W-1:0]  rd_addr, wr_addr;
    wire [P-1:0]       rd_data, wr_data;

    ca_pipeline_engine #(.WIDTH(W), .HEIGHT(H), .P(P), .MEM_LAT(MEM_LAT), .STAGES(K)) dut (
        .clk(clk), .rst(rst), .start(start), .rule(rule), .busy(busy), .done(done),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_en(wr_en)
    );

    // word memories with a MEM_LAT-cycle registered read
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
    // reference: flat cell array; rows outside 0..H-1 read as dead
    // ------------------------------------------------------------------
    reg ref_cur [0:NCELL-1];
    reg ref_nxt [0:NCELL-1];

    task automatic ref_step(input [17:0] rl);
        integer r, c, dr, dc, s, rr;
        begin
            for (r = 0; r < H; r = r + 1)
                for (c = 0; c < W; c = c + 1) begin
                    s = 0;
                    for (dr = -1; dr <= 1; dr = dr + 1)
                        for (dc = -1; dc <= 1; dc = dc + 1)
                            if (dr != 0 || dc != 0) begin
                                rr = r + dr;
                                if (rr >= 0 && rr < H)
                                    s = s + ref_cur[rr*W + ((c+dc+W)%W)];
                            end
                    ref_nxt[r*W+c] = ref_cur[r*W+c] ? rl[9+s] : rl[s];
                end
            for (r = 0; r < NCELL; r = r + 1)
                ref_cur[r] = ref_nxt[r];
        end
    endtask

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

    task automatic check_pass(input integer ri, input integer ps);
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
                        $display("[W%0d H%0d P%0d L%0d K%0d] rule %0d pass %0d: word %0d written %0d times",
                                 W, H, P, MEM_LAT, K, ri, ps, a, wcount[a]);
                    e = e + 1;
                end else if (got !== want) begin
                    if (e < 4)
                        $display("[W%0d H%0d P%0d L%0d K%0d] rule %0d pass %0d: word %0d got %h want %h",
                                 W, H, P, MEM_LAT, K, ri, ps, a, got, want);
                    e = e + 1;
                end
            end
            errors = errors + e;
        end
    endtask

    integer    seed, ri, ps, i, guard, g, cycles;
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
                2: cur_rule = {9'b000000010, 9'b000000010};   // Gnarl       B1/S1
                3: cur_rule = {9'b111011000, 9'b111001000};   // Day & Night
                default: cur_rule = $random(seed);            // random 18-bit rule
            endcase

            for (i = 0; i < NCELL; i = i + 1)
                ref_cur[i] = (($random(seed) & 7) < 3);
            load_mem;

            for (ps = 0; ps < PASSES; ps = ps + 1) begin
                for (i = 0; i < NWORD; i = i + 1) begin
                    nxt_mem[i] = {P{1'bx}};
                    wcount[i]  = 0;
                end

                rule  <= cur_rule;
                start <= 1'b1;
                @(posedge clk);
                start <= 1'b0;
                rule  <= $random(seed);                       // must be ignored

                guard = 0;
                cycles = 1;
                @(posedge clk); #1;
                while (done !== 1'b1) begin
                    @(posedge clk); #1;
                    cycles = cycles + 1;
                    guard  = guard + 1;
                    if (guard > 50*NWORD + 200*K*(W/P + 8) + 10000) begin
                        $display("[W%0d H%0d P%0d L%0d K%0d] TIMEOUT: rule %0d pass %0d",
                                 W, H, P, MEM_LAT, K, ri, ps);
                        $finish;
                    end
                end
                @(posedge clk); #1;

                for (g = 0; g < K; g = g + 1)
                    ref_step(cur_rule);
                check_pass(ri, ps);

                for (i = 0; i < NWORD; i = i + 1)
                    cur_mem[i] = nxt_mem[i];
            end
        end

        $display("W=%0d H=%0d P=%0d MEM_LAT=%0d K=%0d: %0d rules x %0d passes, %0d cycles/pass -- %s (%0d errors)",
                 W, H, P, MEM_LAT, K, NRULES, PASSES, cycles, (errors == 0) ? "PASS" : "FAIL", errors);
        finished = 1'b1;
    end

endmodule


module tb_ca_pipeline_engine;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire        f0, f1, f2, f3, f4, f5, f6, f7;
    wire [31:0] e0, e1, e2, e3, e4, e5, e6, e7;

    ca_pipe_checker #(.W(16), .H(8),  .P(4),  .MEM_LAT(1), .K(1),  .SEED(11)) c0 (clk, f0, e0);
    ca_pipe_checker #(.W(16), .H(8),  .P(4),  .MEM_LAT(1), .K(2),  .SEED(22)) c1 (clk, f1, e1);
    ca_pipe_checker #(.W(16), .H(8),  .P(1),  .MEM_LAT(1), .K(3),  .SEED(33)) c2 (clk, f2, e2);
    ca_pipe_checker #(.W(16), .H(8),  .P(16), .MEM_LAT(1), .K(3),  .SEED(44)) c3 (clk, f3, e3);
    ca_pipe_checker #(.W(24), .H(5),  .P(8),  .MEM_LAT(1), .K(4),  .SEED(55)) c4 (clk, f4, e4);
    ca_pipe_checker #(.W(16), .H(8),  .P(4),  .MEM_LAT(2), .K(8),  .SEED(66)) c5 (clk, f5, e5);
    ca_pipe_checker #(.W(64), .H(16), .P(32), .MEM_LAT(2), .K(4),  .SEED(77)) c6 (clk, f6, e6);
    ca_pipe_checker #(.W(64), .H(12), .P(32), .MEM_LAT(2), .K(32), .PASSES(2), .SEED(88)) c7 (clk, f7, e7);

    initial begin
        wait (f0 && f1 && f2 && f3 && f4 && f5 && f6 && f7);
        if ((e0 + e1 + e2 + e3 + e4 + e5 + e6 + e7) == 0)
            $display("ALL CONFIGURATIONS PASSED");
        else
            $display("FAILED: %0d total errors", e0 + e1 + e2 + e3 + e4 + e5 + e6 + e7);
        $finish;
    end

endmodule
