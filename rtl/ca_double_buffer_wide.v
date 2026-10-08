// ============================================================================
// ca_double_buffer_wide.v
//
// Word-wide version of ca_double_buffer: two ping-ponged state buffers of
// P-bit words around ca_update_engine_wide. Each buffer is written in the
// standard Xilinx true-dual-port block RAM template, so at 640x480 both land
// in dedicated BRAM instead of replicated LUT RAM:
//
//   port A (read/write): the engine. The CURRENT buffer is read (by the
//           engine, or by the aux reader while the engine is idle); the NEXT
//           buffer is written. The boot loader also writes buffer 0 here.
//   port B (read only):  the display, addressed every cycle.
//
// READ LATENCY
//   MEM_LAT = 1: plain synchronous read.
//   MEM_LAT = 2: adds an output register, which Vivado absorbs into the BRAM
//                (DOA_REG/DOB_REG). Better Fmax, one more cycle of latency --
//                passed straight through to the engine so its pipeline
//                accounting stays correct.
//
// CONTRACT (same as ca_double_buffer)
//   * `start` runs N_GENS generations; `done` pulses after the final swap.
//   * Swaps are gated on the engine's `done`, never its `busy`.
//   * cur_buf is forced to 0 only on the first start after reset (buffer 0
//     holds the boot-loaded seed); later starts continue from wherever the
//     last swap left it.
//   * load_en / aux_sel may only be used while the engine is idle.
// ============================================================================

module ca_double_buffer_wide #(
    parameter WIDTH   = 640,
    parameter HEIGHT  = 480,
    parameter P       = 32,
    parameter MEM_LAT = 2,        // 1 or 2
    parameter N_GENS  = 1,

    localparam WORDS  = WIDTH / P,
    localparam NWORD  = HEIGHT * WORDS,
    localparam ADDR_W = (NWORD > 1) ? $clog2(NWORD) : 1
) (
    input  wire              clk,
    input  wire              rst,         // sync, active high

    input  wire              start,       // 1-cycle pulse, only while !busy
    input  wire [17:0]       rule,
    output reg               busy,
    output reg               done,        // 1-cycle pulse when all N_GENS complete
    output reg               cur_buf,     // which buffer holds the latest generation

    // boot loader: writes buffer 0 while idle, before the first start
    input  wire              load_en,
    input  wire [ADDR_W-1:0] load_addr,
    input  wire [P-1:0]      load_data,

    // aux reader: reads the CURRENT buffer through port A while idle.
    // Data appears on cur_word MEM_LAT cycles after aux_addr.
    input  wire              aux_sel,
    input  wire [ADDR_W-1:0] aux_addr,
    output wire [P-1:0]      cur_word,

    // display: port B of both buffers, disp_sel picks which one to show.
    // Data appears on disp_word MEM_LAT cycles after disp_addr.
    input  wire [ADDR_W-1:0] disp_addr,
    input  wire              disp_sel,
    output wire [P-1:0]      disp_word
);

    // ------------------------------------------------------------------
    // engine
    // ------------------------------------------------------------------
    reg               engine_start;
    wire              engine_busy;
    wire              engine_done;
    wire [ADDR_W-1:0] e_rd_addr;
    wire [ADDR_W-1:0] e_wr_addr;
    wire [P-1:0]      e_wr_data;
    wire              e_wr_en;

    ca_update_engine_wide #(.WIDTH(WIDTH), .HEIGHT(HEIGHT), .P(P), .MEM_LAT(MEM_LAT)) engine (
        .clk     (clk),
        .rst     (rst),
        .start   (engine_start),
        .rule    (rule),
        .busy    (engine_busy),
        .done    (engine_done),
        .rd_addr (e_rd_addr),
        .rd_data (cur_word),
        .wr_addr (e_wr_addr),
        .wr_data (e_wr_data),
        .wr_en   (e_wr_en)
    );

    // read address for the current buffer: engine, or aux while idle
    wire [ADDR_W-1:0] rd_addr = aux_sel ? aux_addr : e_rd_addr;

    // ------------------------------------------------------------------
    // port A steering
    //   cur_buf = 0: buffer 0 is read, buffer 1 is written
    //   cur_buf = 1: buffer 1 is read, buffer 0 is written
    //   load_en overrides buffer 0 (boot only, engine idle, cur_buf = 0)
    // ------------------------------------------------------------------
    wire              a0_we   = load_en | (cur_buf & e_wr_en);
    wire [ADDR_W-1:0] a0_addr = load_en ? load_addr : (cur_buf ? e_wr_addr : rd_addr);
    wire [P-1:0]      a0_din  = load_en ? load_data : e_wr_data;

    wire              a1_we   = ~cur_buf & e_wr_en;
    wire [ADDR_W-1:0] a1_addr = cur_buf ? rd_addr : e_wr_addr;
    wire [P-1:0]      a1_din  = e_wr_data;

    // ------------------------------------------------------------------
    // buffers: Xilinx true-dual-port BRAM template
    // ------------------------------------------------------------------
    reg [P-1:0] mem0 [0:NWORD-1];
    reg [P-1:0] mem1 [0:NWORD-1];

    reg [P-1:0] a0_q1, a0_q2, b0_q1, b0_q2;
    reg [P-1:0] a1_q1, a1_q2, b1_q1, b1_q2;

    always @(posedge clk) begin                 // buffer 0, port A
        if (a0_we) mem0[a0_addr] <= a0_din;
        a0_q1 <= mem0[a0_addr];
        a0_q2 <= a0_q1;
    end

    always @(posedge clk) begin                 // buffer 0, port B
        b0_q1 <= mem0[disp_addr];
        b0_q2 <= b0_q1;
    end

    always @(posedge clk) begin                 // buffer 1, port A
        if (a1_we) mem1[a1_addr] <= a1_din;
        a1_q1 <= mem1[a1_addr];
        a1_q2 <= a1_q1;
    end

    always @(posedge clk) begin                 // buffer 1, port B
        b1_q1 <= mem1[disp_addr];
        b1_q2 <= b1_q1;
    end

    wire [P-1:0] a0_dout = (MEM_LAT == 2) ? a0_q2 : a0_q1;
    wire [P-1:0] a1_dout = (MEM_LAT == 2) ? a1_q2 : a1_q1;
    wire [P-1:0] b0_dout = (MEM_LAT == 2) ? b0_q2 : b0_q1;
    wire [P-1:0] b1_dout = (MEM_LAT == 2) ? b1_q2 : b1_q1;

    // cur_buf only changes while nothing is reading (right after the engine's
    // done), so selecting with its present value is safe
    assign cur_word  = cur_buf  ? a1_dout : a0_dout;
    assign disp_word = disp_sel ? b1_dout : b0_dout;

    // ------------------------------------------------------------------
    // sequencing FSM (unchanged from ca_double_buffer)
    // ------------------------------------------------------------------
    localparam S_IDLE = 2'd0,
               S_WAIT = 2'd1,
               S_SWAP = 2'd2,
               S_FIN  = 2'd3;

    reg [1:0]                  state;
    reg [$clog2(N_GENS+1)-1:0] gen_count;
    reg                        started_once;

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            cur_buf      <= 1'b0;
            gen_count    <= 0;
            engine_start <= 1'b0;
            started_once <= 1'b0;
        end else begin
            engine_start <= 1'b0;
            done         <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        busy <= 1'b1;
                        // only the first start after reset rewinds to the
                        // boot-loaded buffer 0 -- see ca_double_buffer.v
                        if (!started_once) cur_buf <= 1'b0;
                        started_once <= 1'b1;
                        gen_count    <= 0;
                        engine_start <= 1'b1;
                        state        <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (engine_done)                   // done, not busy
                        state <= S_SWAP;
                end

                S_SWAP: begin
                    cur_buf <= ~cur_buf;
                    if (gen_count == N_GENS - 1) begin
                        state <= S_FIN;
                    end else begin
                        gen_count    <= gen_count + 1'b1;
                        engine_start <= 1'b1;
                        state        <= S_WAIT;
                    end
                end

                S_FIN: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
