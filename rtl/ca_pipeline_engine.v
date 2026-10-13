// ============================================================================
// ca_pipeline_engine.v
//
// Temporal pipeline: STAGES copies of the CA datapath in series, so one pass
// through memory computes STAGES generations. Memory traffic is unchanged
// (one word read and one written per clock), so throughput scales with
// STAGES while BRAM bandwidth stays the same -- the classic FPGA answer to a
// bandwidth-bound stencil.
//
//   memory --read--> [zero-pad] -> stage 0 -> stage 1 -> ... -> stage K-1 --write--> memory
//
// BOUNDARIES
//   Rows wrap horizontally (as in ca_update_engine_wide). The top and bottom
//   edges are DEAD: the cells above row 0 and below row HEIGHT-1 are always
//   0. (Vertical wraparound would need row HEIGHT-1 of each generation before
//   row 0 of the next, which a streaming pipeline cannot have without
//   buffering a whole frame per stage.)
//
// INTERFACE
//   Same ports and contract as ca_update_engine_wide, so ca_double_buffer_wide
//   can use either: pulse `start` while idle; `done` pulses with the final
//   write. The read address is registered (data arrives MEM_LAT + 1 cycles
//   after the scan counters). `busy` covers the input scan only.
//
// LATENCY / THROUGHPUT
//   A pass streams NROWS*PWORDS words; each stage adds 2*WORDS + 7 cycles of
//   latency (ca_stage.v). Cells per clock = STAGES * WIDTH*HEIGHT / pass cycles.
// ============================================================================

module ca_pipeline_engine #(
    parameter WIDTH   = 640,
    parameter HEIGHT  = 480,
    parameter P       = 32,
    parameter MEM_LAT = 2,
    parameter STAGES  = 32,

    localparam WORDS  = WIDTH / P,
    localparam ADDR_W = (HEIGHT*WORDS > 1) ? $clog2(HEIGHT*WORDS) : 1
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire [17:0]       rule,      // {survive[8:0], birth[8:0]}

    output reg               busy,
    output reg               done,

    output reg  [ADDR_W-1:0] rd_addr,
    input  wire [P-1:0]      rd_data,   // arrives MEM_LAT cycles after rd_addr

    output reg  [ADDR_W-1:0] wr_addr,
    output reg  [P-1:0]      wr_data,
    output reg               wr_en
);

    localparam PWORDS = WORDS + 2;
    localparam NROWS  = HEIGHT + 2;
    localparam PW_W   = $clog2(PWORDS);
    localparam PROW_W = $clog2(NROWS);
    localparam ROW_W  = (HEIGHT > 1) ? $clog2(HEIGHT) : 1;
    localparam WORD_W = (WORDS  > 1) ? $clog2(WORDS)  : 1;
    localparam RD_LAT = MEM_LAT + 1;               // registered rd_addr + memory

    // ------------------------------------------------------------------
    // reader: padded (row, word) scan. Padded rows 0 and NROWS-1 are zeroed
    // on the way in (their address is irrelevant; row 0 is used).
    // ------------------------------------------------------------------
    reg [PROW_W-1:0] prow;
    reg [PW_W-1:0]   pw;
    reg              running;
    reg [17:0]       rule_q;

    wire [ROW_W-1:0]  actual_row  = (prow == 0 || prow == NROWS-1) ? 0 : (prow - 1'b1);
    wire [WORD_W-1:0] actual_word = (pw == 0)        ? (WORDS-1) :
                                    (pw == PWORDS-1) ? 0         :
                                                       (pw - 1'b1);

    always @(posedge clk) rd_addr <= actual_row * WORDS + actual_word;

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
            rule_q  <= rule;                        // one rule per pass
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

    // frame start and zero-row flag, delayed to line up with rd_data
    reg [RD_LAT-1:0] sof_d, zero_d;
    always @(posedge clk) begin
        if (rst) begin
            sof_d  <= 0;
            zero_d <= 0;
        end else begin
            sof_d  <= {sof_d[RD_LAT-2:0],  running && prow == 0 && pw == 0};
            zero_d <= {zero_d[RD_LAT-2:0], prow == 0 || prow == NROWS-1};
        end
    end

    // ------------------------------------------------------------------
    // the stage chain
    // ------------------------------------------------------------------
    wire [STAGES:0]       s_sof;
    wire [(STAGES+1)*P-1:0]  s_data;
    wire [(STAGES+1)*18-1:0] s_rule;

    assign s_sof[0]       = sof_d[RD_LAT-1];
    assign s_data[P-1:0]  = zero_d[RD_LAT-1] ? {P{1'b0}} : rd_data;
    assign s_rule[17:0]   = rule_q;

    wire              f_real, f_last;
    wire [ROW_W-1:0]  f_row;
    wire [WORD_W-1:0] f_word;
    wire [P-1:0]      f_data;

    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : stage
            wire              c_real, c_last;
            wire [ROW_W-1:0]  c_row;
            wire [WORD_W-1:0] c_word;
            wire [P-1:0]      c_data;

            ca_stage #(.WIDTH(WIDTH), .HEIGHT(HEIGHT), .P(P)) u (
                .clk      (clk),
                .rst      (rst),
                .in_sof   (s_sof[i]),
                .in_data  (s_data[i*P +: P]),
                .in_rule  (s_rule[i*18 +: 18]),
                .out_sof  (s_sof[i+1]),
                .out_data (s_data[(i+1)*P +: P]),
                .out_rule (s_rule[(i+1)*18 +: 18]),
                .c_real   (c_real),
                .c_row    (c_row),
                .c_word   (c_word),
                .c_last   (c_last),
                .c_data   (c_data)
            );

            if (i == STAGES-1) begin : last
                assign f_real = c_real;
                assign f_last = c_last;
                assign f_row  = c_row;
                assign f_word = c_word;
                assign f_data = c_data;
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // writer: the last stage's real words go back to memory
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            wr_en   <= 1'b0;
            wr_addr <= 0;
            wr_data <= 0;
            done    <= 1'b0;
        end else begin
            wr_en <= f_real;
            if (f_real) begin
                wr_addr <= f_row * WORDS + f_word;
                wr_data <= f_data;
            end
            done <= f_last;
        end
    end

endmodule
