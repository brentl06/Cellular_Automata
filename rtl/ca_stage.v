// ============================================================================
// ca_stage.v
//
// One generation of the temporal pipeline (ca_pipeline_engine.v): a padded
// word stream in, the next generation out -- both as a padded stream for the
// next stage and as plain (row, word) results for the memory writer.
//
// INPUT STREAM
//   NROWS = HEIGHT+2 padded rows of PWORDS = WORDS+2 words, one word per
//   clock, no gaps. `in_sof` pulses with padded slot (0, 0). Padded row 0 and
//   row HEIGHT+1 are all zeros (dead top/bottom edges). In every row, slot 0
//   repeats the row's last word and slot PWORDS-1 its first word (horizontal
//   wraparound). `in_rule` is latched at `in_sof`.
//
// DATAPATH
//   Identical to ca_update_engine_wide: two line buffers of one padded row,
//   prev/cur/next word registers, P lanes of neighbor count + rule lookup.
//   The center of the window is padded slot (R, J) at in_sof + (R+1)*PWORDS
//   + J + 2 cycles; it is a real cell word for R in 1..HEIGHT, J in 1..WORDS.
//
// RE-PADDING
//   The next stage needs each row as  w[WORDS-1], w[0..WORDS-1], w[0], but
//   w[WORDS-1] is the LAST word this stage produces for the row. So each row
//   is written into one half of a two-row buffer and emitted, padded, as soon
//   as its last word exists, while the next row fills the other half. The
//   stream keeps its exact rhythm (the two padding slots per row already
//   exist), so re-padding costs latency, not throughput:
//     stage latency D = PWORDS + WORDS + 5 = 2*WORDS + 7 cycles (sof to sof).
//   Each new word is registered before it is stored: count -> rule lookup ->
//   LUTRAM write-data setup was the critical path at 150 MHz with 32 stages
//   (WNS -0.007 ns). The c_* outputs are those registered values.
//   Padded rows 0 and HEIGHT+1 are emitted as zeros.
//
// TIMING NOTES
//   The rule is latched per stage and passed down the chain (out_rule), so
//   rule bits never fan out to every stage at once. out_sof/out_data are
//   registered.
// ============================================================================

module ca_stage #(
    parameter WIDTH  = 640,
    parameter HEIGHT = 480,
    parameter P      = 32,

    localparam WORDS  = WIDTH / P,
    localparam ROW_W  = (HEIGHT > 1) ? $clog2(HEIGHT) : 1,
    localparam WORD_W = (WORDS  > 1) ? $clog2(WORDS)  : 1
) (
    input  wire              clk,
    input  wire              rst,

    input  wire              in_sof,
    input  wire [P-1:0]      in_data,
    input  wire [17:0]       in_rule,

    output reg               out_sof,
    output reg  [P-1:0]      out_data,
    output wire [17:0]       out_rule,

    output reg               c_real,     // c_data is a real cell word of the new generation
    output reg  [ROW_W-1:0]  c_row,
    output reg  [WORD_W-1:0] c_word,
    output reg               c_last,     // ... and it is the last one
    output reg  [P-1:0]      c_data
);

    localparam PWORDS = WORDS + 2;
    localparam NROWS  = HEIGHT + 2;
    localparam PW_W   = $clog2(PWORDS);
    localparam PROW_W = $clog2(NROWS);
    localparam BUF_W  = (2*WORDS > 1) ? $clog2(2*WORDS) : 1;

    // ------------------------------------------------------------------
    // rule: latched at the start of this stage's frame
    // ------------------------------------------------------------------
    reg [17:0] rule_q;
    always @(posedge clk)
        if (in_sof) rule_q <= in_rule;
    assign out_rule = rule_q;

    // ------------------------------------------------------------------
    // line buffers + window (same as ca_update_engine_wide)
    // ------------------------------------------------------------------
    reg [P-1:0]    lb1 [0:PWORDS-1];
    reg [P-1:0]    lb2 [0:PWORDS-1];
    reg [PW_W-1:0] lptr;

    wire [P-1:0] s0 = in_data;
    wire [P-1:0] s1 = lb1[lptr];
    wire [P-1:0] s2 = lb2[lptr];

    always @(posedge clk) begin
        lb1[lptr] <= s0;
        lb2[lptr] <= s1;
    end

    always @(posedge clk) begin
        if (rst) lptr <= 0;
        else     lptr <= (lptr == PWORDS-1) ? {PW_W{1'b0}} : lptr + 1'b1;
    end

    reg [P-1:0] a_prev, a_cur, a_next;
    reg [P-1:0] b_prev, b_cur, b_next;
    reg [P-1:0] c_prev, c_cur, c_next;

    always @(posedge clk) begin
        a_next <= s2;  a_cur <= a_next;  a_prev <= a_cur;
        b_next <= s1;  b_cur <= b_next;  b_prev <= b_cur;
        c_next <= s0;  c_cur <= c_next;  c_prev <= c_cur;
    end

    wire [P+1:0] a_ext = {a_next[0], a_cur, a_prev[P-1]};
    wire [P+1:0] b_ext = {b_next[0], b_cur, b_prev[P-1]};
    wire [P+1:0] c_ext = {c_next[0], c_cur, c_prev[P-1]};

    wire [8:0]   birth_rule   = rule_q[8:0];
    wire [8:0]   survive_rule = rule_q[17:9];
    wire [P-1:0] next_word;

    genvar j;
    generate
        for (j = 0; j < P; j = j + 1) begin : lane
            wire [3:0] sum = a_ext[j] + a_ext[j+1] + a_ext[j+2] +
                             b_ext[j]              + b_ext[j+2] +
                             c_ext[j] + c_ext[j+1] + c_ext[j+2];
            wire center = b_ext[j+1];
            assign next_word[j] = center ? survive_rule[sum] : birth_rule[sum];
        end
    endgenerate

    // ------------------------------------------------------------------
    // center position: (cr, cj) is the padded slot at the window center.
    // in_sof delayed PWORDS+1 cycles loads (0, 0), which is then the center
    // during the next cycle (in_sof + PWORDS + 2).
    // ------------------------------------------------------------------
    reg [PWORDS:0] sof_dly;
    always @(posedge clk) begin
        if (rst) sof_dly <= 0;
        else     sof_dly <= {sof_dly[PWORDS-1:0], in_sof};
    end
    wire c_load = sof_dly[PWORDS];

    reg              cact;
    reg [PROW_W-1:0] cr;
    reg [PW_W-1:0]   cj;

    always @(posedge clk) begin
        if (rst) begin
            cact <= 1'b0;
            cr   <= 0;
            cj   <= 0;
        end else if (c_load) begin
            cact <= 1'b1;
            cr   <= 0;
            cj   <= 0;
        end else if (cact) begin
            if (cj == PWORDS-1) begin
                cj <= 0;
                if (cr == NROWS-1) cact <= 1'b0;
                else               cr   <= cr + 1'b1;
            end else begin
                cj <= cj + 1'b1;
            end
        end
    end

    wire center_real = cact && (cr >= 1) && (cr <= HEIGHT) && (cj >= 1) && (cj <= WORDS);

    // register the new word and its position (one cycle after the center)
    reg             c_par;                  // parity of the center row
    always @(posedge clk) begin
        if (rst) begin
            c_real <= 1'b0;
            c_last <= 1'b0;
        end else begin
            c_real <= center_real;
            c_last <= center_real && (cr == HEIGHT) && (cj == WORDS);
        end
        c_row  <= cr - 1'b1;
        c_word <= cj - 1'b1;
        c_par  <= cr[0];
        c_data <= next_word;
    end

    // ------------------------------------------------------------------
    // re-padder: two-row ping-pong buffer, half = parity of the center row
    // ------------------------------------------------------------------
    reg [P-1:0] rbuf [0:2*WORDS-1];
    wire [BUF_W-1:0] wr_idx = (c_par ? WORDS : 0) + c_word;

    always @(posedge clk)
        if (c_real) rbuf[wr_idx] <= c_data;

    // Row R' finishes writing (registered) while the center is (R', WORDS+1),
    // so its padded emission starts with the next center, (R'+1, 0).
    // (er, ee) is the output slot.
    wire e_load = cact && (cr == 0) && (cj == PWORDS-1);

    reg              eact;
    reg [PROW_W-1:0] er;
    reg [PW_W-1:0]   ee;

    always @(posedge clk) begin
        if (rst) begin
            eact <= 1'b0;
            er   <= 0;
            ee   <= 0;
        end else if (e_load) begin
            eact <= 1'b1;
            er   <= 0;
            ee   <= 0;
        end else if (eact) begin
            if (ee == PWORDS-1) begin
                ee <= 0;
                if (er == NROWS-1) eact <= 1'b0;
                else               er   <= er + 1'b1;
            end else begin
                ee <= ee + 1'b1;
            end
        end
    end

    wire [WORD_W-1:0] e_word = (ee == 0)        ? (WORDS-1) :
                               (ee == PWORDS-1) ? 0         :
                                                  (ee - 1'b1);
    wire [BUF_W-1:0]  rd_idx = (er[0] ? WORDS : 0) + e_word;
    wire              e_zero = (er == 0) || (er == NROWS-1);

    always @(posedge clk) begin
        if (rst) begin
            out_sof  <= 1'b0;
            out_data <= 0;
        end else begin
            out_sof  <= eact && (er == 0) && (ee == 0);
            out_data <= e_zero ? {P{1'b0}} : rbuf[rd_idx];
        end
    end

endmodule
