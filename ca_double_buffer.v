// ============================================================================
// ca_double_buffer.v
//
// Wraps ca_update_engine with two ping-ponged single-bit state buffers
// (mem0/mem1) and a sequencing FSM so the engine can run N_GENS generations
// back-to-back with no host intervention between generations. This is what
// ca_update_engine itself does NOT do -- it only knows how to run one
// generation given a "current" read port and a "next" write port; something
// has to own two physical buffers, swap which one is "current" after each
// generation, and re-trigger the engine.
//
// CORRECTNESS NOTE -- swap on `done`, not `busy`:
//   ca_update_engine's `busy` tracks only the INPUT-side raster scan and
//   drops as soon as the last (row,col) address has been issued. The
//   output pipeline is still draining for TOTAL_LATENCY more cycles after
//   that -- the last several writes into the "next" buffer land AFTER busy
//   already reads 0. Swapping buffers or re-starting the engine on
//   busy==0 would begin generation N+1's reads before generation N's last
//   few writes have actually landed, silently corrupting a handful of
//   cells near the end of the raster every generation. `done` (pulsed
//   after the very last write commits) is the correctly-delayed signal to
//   gate on. This is the same class of bug (latency mis-accounting) that
//   the engine itself hit once already -- see ca_update_engine.v's
//   TOTAL_LATENCY comment -- so it's called out here explicitly rather
//   than trusted to be obvious.
//
// RESOURCE NOTE:
//   mem0/mem1 are WIDTH*HEIGHT bits each. At 640x480 that's ~300Kbit per
//   buffer, ~600Kbit combined, out of the GW2AR-18's 828Kbit of BSRAM --
//   leaves headroom for the two line buffers inside the engine plus
//   whatever the video/display path needs, but it's not a lot of slack at
//   full frame size.
// ============================================================================

module ca_double_buffer #(
    parameter WIDTH   = 640,
    parameter HEIGHT  = 480,
    parameter N_GENS  = 8,
    localparam ADDR_W = $clog2(WIDTH*HEIGHT)
) (
    input  wire              clk,
    input  wire              rst,       // sync, active high

    // top-level control: run N_GENS generations back-to-back
    input  wire              start,     // 1-cycle pulse, only valid while !busy
    input wire [17:0]        rule,
    output reg               busy,
    output reg               done,      // 1-cycle pulse when all N_GENS complete

    // load port: seed the initial state before asserting start.
    // Only safe to drive while busy == 0 -- it always targets mem0, and
    // mem0 is only guaranteed to be "current" (cur_buf == 0) before the
    // first start pulse.
    input  wire               load_en,
    input  wire [ADDR_W-1:0]  load_addr,
    input  wire               load_data,

    // read-out port: reads whichever buffer is "current" (i.e. the most
    // recently fully-completed generation). Safe to read continuously;
    // during a run it reflects the last completed generation until the
    // in-flight one's `done` swaps it forward.
    input  wire [ADDR_W-1:0]  out_addr,
    output reg                out_data,
    
    // independent read port for the UART streamer
    input  wire [ADDR_W-1:0]  uart_addr,
    output reg                uart_data
);

    reg mem0 [0:WIDTH*HEIGHT-1];
    reg mem1 [0:WIDTH*HEIGHT-1];

    reg cur_buf;   // 0: mem0 is current (engine reads mem0, writes mem1)
                   // 1: mem1 is current (engine reads mem1, writes mem0)

    reg [$clog2(N_GENS+1)-1:0] gen_count;

    // ------------------------------------------------------------------
    // engine instance
    // ------------------------------------------------------------------
    reg               engine_start;
    wire              engine_busy;
    wire              engine_done;
    wire [ADDR_W-1:0] engine_rd_addr;
    reg               engine_rd_data;
    wire [ADDR_W-1:0] engine_wr_addr;
    wire              engine_wr_data;
    wire              engine_wr_en;

    ca_update_engine #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) engine (
        .clk     (clk),
        .rst     (rst),
        .start   (engine_start),
        .rule    (rule),
        .busy    (engine_busy),
        .done    (engine_done),
        .rd_addr (engine_rd_addr),
        .rd_data (engine_rd_data),
        .wr_addr (engine_wr_addr),
        .wr_data (engine_wr_data),
        .wr_en   (engine_wr_en)
    );

    // registered read of whichever buffer is "current" -- matches the
    // registered-read (1-cycle-latency) timing ca_update_engine.v's
    // TOTAL_LATENCY assumes for its external memory.
    always @(posedge clk) begin
        engine_rd_data <= cur_buf ? mem1[engine_rd_addr] : mem0[engine_rd_addr];
    end

    // write into whichever buffer is NOT current; load_en (only used while
    // idle) always targets mem0 directly and takes priority.
    always @(posedge clk) begin
        if (load_en) begin
            mem0[load_addr] <= load_data;
        end else if (engine_wr_en) begin
            if (cur_buf) mem0[engine_wr_addr] <= engine_wr_data;
            else         mem1[engine_wr_addr] <= engine_wr_data;
        end
    end

    // external read-out port, from whichever buffer is current
    always @(posedge clk) begin
        out_data <= cur_buf ? mem1[out_addr] : mem0[out_addr];
    end
    
        always @(posedge clk) begin
        uart_data <= cur_buf ? mem1[uart_addr] : mem0[uart_addr];
    end

    // ------------------------------------------------------------------
    // sequencing FSM
    // ------------------------------------------------------------------
    localparam S_IDLE = 2'd0,
               S_WAIT = 2'd1,
               S_SWAP = 2'd2,
               S_FIN  = 2'd3;

    reg [1:0] state;

    // Set on the first-ever `start` after reset, held thereafter. Needed
    // because S_IDLE must only force cur_buf back to 0 (mem0, freshly
    // seeded via load_en) on that FIRST call -- see comment below.
    reg started_once;

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            busy           <= 1'b0;
            done           <= 1'b0;
            cur_buf        <= 1'b0;
            gen_count      <= 0;
            engine_start   <= 1'b0;
            started_once   <= 1'b0;
        end else begin
            engine_start <= 1'b0;   // default: 1-cycle pulse only
            done         <= 1'b0;   // default: 1-cycle pulse only

            case (state)
                S_IDLE: begin
                    if (start) begin
                        busy <= 1'b1;
                        // Only the FIRST call after reset should force
                        // cur_buf to 0 -- that's the one time mem0 is
                        // guaranteed to hold the freshly-loaded seed. Every
                        // later call (e.g. one `start` pulse per generation,
                        // paced externally frame-by-frame, as
                        // ca_video_core does) must leave cur_buf exactly
                        // where the previous run's S_SWAP left it;
                        // resetting it here on every call would silently
                        // rewind playback back to the original seed every
                        // single time instead of continuing forward.
                        if (!started_once) cur_buf <= 1'b0;
                        started_once <= 1'b1;
                        gen_count    <= 0;
                        engine_start <= 1'b1;
                        state        <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    // deliberately gated on engine_done, not engine_busy --
                    // see CORRECTNESS NOTE above.
                    if (engine_done)
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
