<img width="480" height="360" alt="ca_hw" src="https://github.com/user-attachments/assets/7ae974d1-286b-412b-9ddf-b86b3fabcce6" />

# Cellular_Automata
This is a cellular automaton accelerator written entirely in Verilog for the Artix-7 FPGA on the Nexys A7 board. A 32-lane streaming datapath updates 32 cells per clock cycle on a 640x480 grid at 100 MHz: line buffers rebuild a 3x3 sliding window each clock, and each cell's neighbor-count sum indexes an 18-bit birth/survival rule, so 16 different cellular automata are selectable at runtime from the board switches. The grid is shown live over VGA (one generation per frame, no tearing) and a 64x48 window can be streamed over UART to make GIFs.

## Results

| | |
|---|---|
| Throughput, measured on hardware | **10,612 cycles per 640x480 generation** (28.95 cells/clock, ~2.9 billion cells/s at 100 MHz) |
| How it was measured | an on-board counter times each generation and shows it on the 7-segment display; it matches the cycle-accurate simulation exactly |
| Timing | met at 100 MHz (post-route WNS +0.613 ns) |
| Resources | 1,106 LUTs (1.7% of the device), 735 FFs, 32.5 BRAM tiles (the two 640x480 state buffers) |
| VGA output | confirmed on a monitor |

**CPU comparison.** A bit-packed, multithreaded C implementation (same runtime-selectable rule) reaches 13.3 billion cells/s on one core and 60.6 billion on six cores of an Apple M3 Pro, so the current FPGA design is not faster than a well-optimized CPU. The FPGA design is limited by memory bandwidth (one word in and out of BRAM per clock) while using 1.7% of the LUTs; the next step below targets that.

## Verification
Every testbench is self-checking against a reference model written independently of the RTL, and checks the design only through its outputs:

- `tb_ca_update_engine_wide.v`: 6 lane/latency configurations x 8 rules (including random rules) against a bit-level reference
- `tb_ca_video_core_wide.v`: the full core, checked from its output pins only (pixel positions derived from sync timing, every frame exactly one generation, UART decoded bit by bit)
- `tb_gen_cycle_display.v`: 7-segment readout decoded from the anode/segment pins
- `tb_nexys_a7_top_wide_perf.v`: the real board top at 640x480 with 32 lanes; the 7-segment display reads 10,612

The tests were mutation-checked: deliberately broken RTL (wrong latency, off-by-one counters, an extra address cycle) is caught. Run them all with Icarus Verilog:

```
bash run_tests.sh
```

## Layout
- `rtl/`: design sources (`nexys_a7_top_wide.v` is the board top)
- `constraints/`: Nexys A7 pin and clock constraints
- `tb/`: testbenches
- `tools/`: GIF maker, NumPy reference, reference GIFs

The original 1-lane design (one cell per clock, 517 LUTs, timing met at 100 MHz) came first; the figure below is its simulation.

## Next steps
- Temporal pipelining: chain engine stages so each pass through memory computes several generations, aiming to beat the 6-core CPU baseline on hardware
- Raise the clock to 150-200 MHz (the display read address, the previous critical path, is now registered)
- Built-in self-test: CA-based pattern generator and signature register, with fault-injection coverage measurements
- Collect the UART-streamed GIFs for every rule



| <img width="922" height="450" alt="Screenshot 2026-09-21 at 3 18 17 PM" src="https://github.com/user-attachments/assets/96f3f262-42d8-47d3-a490-a04daa84a4e3" /> |
| --- |
| Figure 1: Simulation run in Vivado for the testbench `tb_ca_video_core.v` (original 1-lane design)|
