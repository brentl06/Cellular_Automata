// ============================================================================
// tb_nexys_a7_top_wide_perf.v
//
// Board-top smoke test for the 7-segment cycles-per-generation readout.
// Runs the real top (640x480, P=32, MEM_LAT=2) for a few generations, reads
// the number from the AN/CA..CG pins, and checks it against the start->done
// interval timed by the testbench. Also prints cells/clock.
//
//   iverilog -g2012 -o sim_top_perf tb_nexys_a7_top_wide_perf.v nexys_a7_top_wide.v \
//       gen_cycle_display.v ca_video_core_wide.v ca_double_buffer_wide.v \
//       ca_update_engine_wide.v vga_timing_ce.v uart_tx.v && vvp sim_top_perf
// ============================================================================
`timescale 1ns/1ps

module tb_nexys_a7_top_wide_perf;

    localparam SCAN_BITS = 2;
    localparam GENS      = 2;

    reg clk = 0;
    always #5 clk = ~clk;

    wire [3:0] r, g, b;
    wire hs, vs, txd, ca, cb, cc, cd, ce, cf, cg, dp;
    wire [7:0] an;

    nexys_a7_top_wide #(.SEG_SCAN_BITS(SCAN_BITS)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(1'b1), .SW(4'd0), .SW15(1'b0),
        .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hs), .VGA_VS(vs),
        .UART_RXD_OUT(txd),
        .CA(ca), .CB(cb), .CC(cc), .CD(cd), .CE(ce), .CF(cf), .CG(cg), .DP(dp),
        .AN(an)
    );

    wire [6:0] seg = {cg, cf, ce, cd, cc, cb, ca};

    function integer decode(input [6:0] s);
        case (s)
            7'b1000000: decode = 0;  7'b1111001: decode = 1;
            7'b0100100: decode = 2;  7'b0110000: decode = 3;
            7'b0011001: decode = 4;  7'b0010010: decode = 5;
            7'b0000010: decode = 6;  7'b1111000: decode = 7;
            7'b0000000: decode = 8;  7'b0010000: decode = 9;
            7'b1111111: decode = 10;
            default:    decode = -1;
        endcase
    endfunction

    task read_display(output integer value);
        integer d [0:7];
        integer i, n, pos;
        begin
            for (n = 0; n < 2 * 8 * (1 << SCAN_BITS); n = n + 1) begin
                @(posedge clk); #1;
                pos = -1;
                for (i = 0; i < 8; i = i + 1) if (!an[i]) pos = i;
                if (pos >= 0) d[pos] = decode(seg);
            end
            value = 0;
            for (i = 7; i >= 0; i = i - 1)
                if (d[i] >= 0 && d[i] <= 9) value = value * 10 + d[i];
        end
    endtask

    // time each generation from the core's pulses (probe only)
    integer t_start, cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    integer gen, shown, expect_c, errors = 0;
    initial begin
        for (gen = 0; gen < GENS; gen = gen + 1) begin
            @(posedge clk); #1;
            while (!dut.gen_start) begin @(posedge clk); #1; end
            t_start = cycle;
            @(posedge clk); #1;
            while (!dut.gen_done) begin @(posedge clk); #1; end
            expect_c = cycle - t_start;
            repeat (50) @(posedge clk);
            read_display(shown);
            if (shown != expect_c) begin
                $display("FAIL gen %0d: display %0d, start->done %0d", gen, shown, expect_c);
                errors = errors + 1;
            end else
                $display("ok   gen %0d: %0d cycles, %.2f cells/clock", gen, shown,
                         307200.0 / shown);
        end
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TESTS FAILED", errors);
        $finish;
    end

    initial begin
        #(40_000_000);   // 4M cycles
        $display("TIMEOUT"); $finish;
    end

endmodule
