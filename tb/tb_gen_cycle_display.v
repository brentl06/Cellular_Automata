// ============================================================================
// tb_gen_cycle_display.v
//
// Self-checking testbench for gen_cycle_display. Pulses start/done with known
// gaps, then reads the number back from the anode/segment pins only (decoding
// each digit as the display scans), and checks it equals the gap. Also checks
// leading-zero blanking and that a stray `done` with no `start` is ignored.
//
//   iverilog -g2012 -o sim_gcd tb_gen_cycle_display.v gen_cycle_display.v && vvp sim_gcd
// ============================================================================
`timescale 1ns/1ps

module tb_gen_cycle_display;

    localparam SCAN_BITS = 2;               // 4 cycles per digit in simulation

    reg clk = 0, rst = 1, start = 0, done = 0;
    wire [7:0] an;
    wire [6:0] seg;
    wire       dp;

    always #5 clk = ~clk;

    gen_cycle_display #(.SCAN_BITS(SCAN_BITS)) dut (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .an(an), .seg(seg), .dp(dp)
    );

    integer errors = 0;

    // segment pattern (active low, {g..a}) -> digit; 10 = blank, -1 = invalid
    function integer decode(input [6:0] s);
        case (s)
            7'b1000000: decode = 0;
            7'b1111001: decode = 1;
            7'b0100100: decode = 2;
            7'b0110000: decode = 3;
            7'b0011001: decode = 4;
            7'b0010010: decode = 5;
            7'b0000010: decode = 6;
            7'b1111000: decode = 7;
            7'b0000000: decode = 8;
            7'b0010000: decode = 9;
            7'b1111111: decode = 10;
            default:    decode = -1;
        endcase
    endfunction

    // Watch the pins for two full scans and rebuild the displayed number.
    task read_display(output integer value, output integer ok);
        integer d [0:7];
        integer seen, i, pos, n, started;
        begin
            for (i = 0; i < 8; i = i + 1) d[i] = -2;
            ok = 1;
            for (n = 0; n < 2 * 8 * (1 << SCAN_BITS); n = n + 1) begin
                @(posedge clk); #1;
                pos = -1; seen = 0;
                for (i = 0; i < 8; i = i + 1)
                    if (!an[i]) begin pos = i; seen = seen + 1; end
                if (seen != 1) begin
                    $display("  FAIL: %0d anodes active (an=%b)", seen, an); ok = 0;
                end else begin
                    d[pos] = decode(seg);
                    if (d[pos] < 0) begin
                        $display("  FAIL: bad segment pattern %b", seg); ok = 0;
                    end
                end
                if (dp !== 1'b1) begin $display("  FAIL: dp lit"); ok = 0; end
            end
            // blanks only as leading zeros; digit 0 never blank
            value = 0; started = 0;
            for (i = 7; i >= 0; i = i - 1) begin
                if (d[i] == -2) begin $display("  FAIL: digit %0d never shown", i); ok = 0; end
                else if (d[i] == 10) begin
                    if (started || i == 0) begin
                        $display("  FAIL: blank digit %0d inside number", i); ok = 0;
                    end
                end else begin
                    if (!started && d[i] == 0 && i != 0) begin
                        $display("  FAIL: leading zero at digit %0d not blanked", i); ok = 0;
                    end
                    started = 1;
                    value = value * 10 + d[i];
                end
            end
        end
    endtask

    task measure(input integer gap);
        integer v, ok, i;
        begin
            @(posedge clk); start <= 1;
            @(posedge clk); start <= 0;
            for (i = 1; i < gap; i = i + 1) @(posedge clk);
            done <= 1;
            @(posedge clk); done <= 0;
            repeat (40) @(posedge clk);            // conversion time
            read_display(v, ok);
            if (!ok || v != gap) begin
                $display("FAIL: gap %0d displayed as %0d", gap, v); errors = errors + 1;
            end else
                $display("ok:   gap %0d displayed as %0d", gap, v);
        end
    endtask

    integer v, ok, t, g;
    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (5) @(posedge clk);

        read_display(v, ok);
        if (!ok || v != 0) begin $display("FAIL: initial display %0d", v); errors = errors + 1; end
        else $display("ok:   initial display 0");

        measure(1);
        measure(9);
        measure(10);
        measure(100);
        measure(10604);
        measure(807);
        measure(123456);
        measure(1000000);
        for (t = 0; t < 10; t = t + 1) begin
            g = 1 + ($urandom % 50000);
            measure(g);
        end

        // stray done without start must not change the value
        @(posedge clk); done <= 1;
        @(posedge clk); done <= 0;
        repeat (40) @(posedge clk);
        read_display(v, ok);
        if (!ok || v != g) begin $display("FAIL: stray done changed value to %0d", v); errors = errors + 1; end
        else $display("ok:   stray done ignored");

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TESTS FAILED", errors);
        $finish;
    end

endmodule
