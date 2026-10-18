// ============================================================================
// clk_gen.v
//
// Board clock generator: the Nexys A7's 100 MHz oscillator into an MMCM,
// out at 100 MHz * MULT / DIV. The MMCM primitive is instantiated directly
// (no Clocking Wizard IP), so the project stays plain source files.
//
//   VCO = 100 MHz * MULT must be 600..1200 MHz on a -1 Artix-7.
//     150 MHz: MULT  9, DIV 6  (VCO  900)
//     200 MHz: MULT 10, DIV 5  (VCO 1000)
//     125 MHz: MULT 10, DIV 8  (VCO 1000)
//     100 MHz: MULT 10, DIV 10 (VCO 1000)
//
// The whole design runs on clk_out (still one clock domain), and it is held
// in reset until `locked` goes high.
//
// SIMULATION
//   Outside synthesis the input clock is passed straight through and `locked`
//   rises after a few cycles. The design is single-clock and every test
//   counts cycles, so the clock's absolute frequency doesn't matter to them.
//   Vivado derives the output clock's constraint from the MMCM settings and
//   the create_clock on the input pin.
// ============================================================================

module clk_gen #(
    parameter integer MULT = 9,
    parameter integer DIV  = 6
) (
    input  wire clk_in,       // 100 MHz
    output wire clk_out,
    output wire locked
);

`ifdef SYNTHESIS
    wire clk_fb, clk_mmcm;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (MULT),
        .CLKOUT0_DIVIDE_F (DIV)
    ) mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_mmcm),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG bufg_out (.I(clk_mmcm), .O(clk_out));
`else
    assign clk_out = clk_in;

    reg [3:0] lock_cnt = 4'd0;
    always @(posedge clk_in)
        if (!lock_cnt[3]) lock_cnt <= lock_cnt + 1'b1;
    assign locked = lock_cnt[3];

    initial if (100 * MULT < 600 || 100 * MULT > 1200) begin
        $display("clk_gen: VCO %0d MHz is outside 600..1200", 100 * MULT);
        $finish;
    end
`endif

endmodule
