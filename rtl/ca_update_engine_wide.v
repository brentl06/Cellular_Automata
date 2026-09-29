// ============================================================================
// ca_update_engine_wide.v
//
// P-lane version of ca_update_engine: computes P cells per clock instead of
// one. Same streaming-stencil architecture -- cascaded line buffers, sliding
// 3x3 window, neighbor-count rule lookup -- with every stage widened from one
// bit to one P-bit word.
//
// MEMORY LAYOUT
//   Each grid row is stored as WORDS = WIDTH/P words of P bits.
//   Cell (r, c) lives at word address r*WORDS + c/P, bit c%P.
//   One read returns P cells, so one word per clock = P cells per clock.
//
// WINDOW
//   P adjacent output cells need P+2 input columns: the P cells of the
//   current word, plus the last bit of the word to the left and the first bit
//   of the word to the right. Each row-stream keeps three words (prev, cur,
//   next) and forms a (P+2)-bit extended vector:
//       ext = {next[0], cur[P-1:0], prev[P-1]}
//   so cell j of the word sits at ext[j+1], with neighbors ext[j] and ext[j+2].
//
// TOROIDAL WRAPAROUND
//   Same padding idea as the 1-lane engine, but word-aligned: each row is
//   streamed as  w[WORDS-1], w[0], w[1], ..., w[WORDS-1], w[0]  and the frame
//   as  row[H-1], row[0], ..., row[H-1], row[0]. The edge neighbors then fall
//   out of ordinary prev/next words; the datapath has no edge logic at all.
//   Cost: 2 padding words per row, i.e. 2/(WORDS+2) overhead
//   (~9% at 640 wide with P=32, versus ~0.3% for the 1-lane engine).
//
// LATENCY
//   rd_addr issued at cycle t  ->  word on rd_data at t + MEM_LAT
//   one padded row of line buffer  +PWORDS  (row above / row below alignment)
//   prev/cur/next word registers   +2       (center = the "cur" word)
//   => LAT = PWORDS + 2 + MEM_LAT cycles from issuing an address to that word
//      being the center of the window.
//   MEM_LAT = 1 matches a plain synchronous BRAM read (identical to the 1-lane
//   engine's ROWLEN + 3). Set MEM_LAT = 2 when the BRAM output register is
//   enabled for higher Fmax -- the whole point of making it a parameter is
//   that forgetting to account for that extra cycle is exactly the bug this
//   project already hit once (TOTAL_LATENCY off by one).
//
// ADDRESS RECOVERY
//   As in the 1-lane engine: instead of carrying (row, word) through a
//   LAT-deep pipe, a 1-bit "running" pulse is delayed LAT cycles and re-runs
//   an identical counter pair.
//
// RULE
//   rule = {survive[8:0], birth[8:0]}, bit N = "N live neighbors".
//   The rule is latched on `start`, so every cell of a generation uses the
//   same rule even if the input (e.g. a board switch) changes mid-generation.
//
// INTERFACE CONTRACT
//   Same as ca_update_engine: pulse `start` while idle; `done` pulses with the
//   final write. `busy` covers only the input scan -- gate buffer swaps on
//   `done`, not `busy`. Requires WIDTH % P == 0.
// ============================================================================

module ca_update_engine_wide #(
    parameter WIDTH   = 640,
    parameter HEIGHT  = 480,
    parameter P       = 32,      // lanes (cells per clock); must divide WIDTH
    parameter MEM_LAT = 1,       // external memory read latency in cycles (>= 1)

    localparam WORDS  = WIDTH / P,
    localparam ADDR_W = (HEIGHT*WORDS > 1) ? $clog2(HEIGHT*WORDS) : 1
) (
    input  wire              clk,
    input  wire              rst,       // sync, active high
    input  wire              start,     // 1-cycle pulse: begin one generation
    input  wire [17:0]       rule,      // {survive[8:0], birth[8:0]}

    output reg               busy,
    output reg               done,      // 1-cycle pulse with the final write

    output wire [ADDR_W-1:0] rd_addr,   // word address into the current buffer
    input  wire [P-1:0]      rd_data,   // arrives MEM_LAT cycles after rd_addr

    output reg  [ADDR_W-1:0] wr_addr,   // word address into the next buffer
    output reg  [P-1:0]      wr_data,
    output reg               wr_en
);

    localparam PWORDS = WORDS + 2;                  // padded words per row
    localparam NROWS  = HEIGHT + 2;                 // padded rows per frame
    localparam PW_W   = $clog2(PWORDS);
    localparam PROW_W = $clog2(NROWS);
    localparam ROW_W  = (HEIGHT > 1) ? $clog2(HEIGHT) : 1;
    localparam WORD_W = (WORDS  > 1) ? $clog2(WORDS)  : 1;
    localparam integer LAT = PWORDS + 2 + MEM_LAT;

    // ------------------------------------------------------------------
    // input scan: padded (row, word) counters -> read address
    // ------------------------------------------------------------------
    reg [PROW_W-1:0] prow;
    reg [PW_W-1:0]   pw;
    reg              running;
    reg [17:0]       rule_q;

    wire [ROW_W-1:0]  actual_row  = (prow == 0)       ? (HEIGHT-1) :
                                    (prow == NROWS-1) ? 0          :
                                                        (prow - 1'b1);
    wire [WORD_W-1:0] actual_word = (pw == 0)         ? (WORDS-1)  :
                                    (pw == PWORDS-1)  ? 0          :
                                                        (pw - 1'b1);

    assign rd_addr = actual_row * WORDS + actual_word;

    always @(posedge clk) begin
        if (rst) begin
            prow    <= 0;
            pw      <= 0;
            running <= 1'b0;
            busy    <= 1'b0;
            rule_q  <= 18'd0;
        end else if (start && !running) begin
            running <= 1'b1;
            busy    <= 1'b1;
            prow    <= 0;
            pw      <= 0;
            rule_q  <= rule;                        // one rule per generation
        end else if (running) begin
            if (pw == PWORDS-1) begin
                pw <= 0;
                if (prow == NROWS-1) begin
                    running <= 1'b0;
                    busy    <= 1'b0;
                end else begin
                    prow <= prow + 1'b1;
                end
            end else begin
                pw <= pw + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // two cascaded line buffers, one padded row of words each.
    // Combinational read / clocked write: the value read at a slot is the
    // one written there exactly PWORDS cycles earlier.
    //   s0 = incoming row, s1 = one row earlier, s2 = two rows earlier
    // ------------------------------------------------------------------
    reg [P-1:0]    lb1 [0:PWORDS-1];
    reg [P-1:0]    lb2 [0:PWORDS-1];
    reg [PW_W-1:0] lptr;

    wire [P-1:0] s0 = rd_data;
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

    // ------------------------------------------------------------------
    // three words per row-stream -> (P+2)-column window
    //   a = row above center (s2), b = center row (s1), c = row below (s0)
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // P independent lanes: neighbor count + rule lookup.
    // Lanes sit side by side, not in series, so the critical path is one
    // popcount plus one lookup regardless of P.
    // ------------------------------------------------------------------
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
    // output-side replay counters (delayed-pulse trick, as in the 1-lane
    // engine): running_p is `running` delayed LAT cycles, and (prow_p, pw_p)
    // re-trace the exact padded position now sitting at the window center.
    // ------------------------------------------------------------------
    reg [LAT-1:0] running_dly;
    always @(posedge clk) begin
        if (rst) running_dly <= {LAT{1'b0}};
        else     running_dly <= {running_dly[LAT-2:0], running};
    end
    wire running_p = running_dly[LAT-1];

    reg [PROW_W-1:0] prow_p;
    reg [PW_W-1:0]   pw_p;

    always @(posedge clk) begin
        if (rst) begin
            prow_p <= 0;
            pw_p   <= 0;
        end else if (running_p) begin
            if (pw_p == PWORDS-1) begin
                pw_p <= 0;
                if (prow_p != NROWS-1)
                    prow_p <= prow_p + 1'b1;
            end else begin
                pw_p <= pw_p + 1'b1;
            end
        end else begin
            prow_p <= 0;                            // idle: ready for next run
            pw_p   <= 0;
        end
    end

    // ------------------------------------------------------------------
    // output: write only real (non-padding) center words
    // ------------------------------------------------------------------
    wire out_valid = running_p &&
                     (prow_p >= 1) && (prow_p <= HEIGHT) &&
                     (pw_p   >= 1) && (pw_p   <= WORDS);

    wire [ROW_W-1:0]  out_row  = prow_p - 1'b1;
    wire [WORD_W-1:0] out_word = pw_p   - 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            wr_en   <= 1'b0;
            wr_addr <= 0;
            wr_data <= 0;
            done    <= 1'b0;
        end else begin
            wr_en   <= out_valid;
            wr_addr <= out_row * WORDS + out_word;
            wr_data <= next_word;
            done    <= out_valid && (out_row == HEIGHT-1) && (out_word == WORDS-1);
        end
    end

endmodule
