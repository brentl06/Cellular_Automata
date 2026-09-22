<img width="480" height="360" alt="ca_hw" src="https://github.com/user-attachments/assets/7ae974d1-286b-412b-9ddf-b86b3fabcce6" />

# Cellular_Automata
This is a cellular automaton accelerator written entirely in Verilog for the Artix-7 FPGA on the Nexys A7 board, processing one cell per clock cycle. Each cell's next state is derived from the neighbor-count sum and gets streamed through line buffers to reconstruct as a 3x3 sliding window. This system has birth/survival rules that allow for up to 16 variant cellular automata states to be generated, selectable at runtime via board switches. Verification of the generated cellular automata was done against independent NumPy reference models, where Verilog self-checking testbenches marked off if the Verilog automata passed or failed. Design fits in 517 LUTs (0.8% of device) with timing at 100 MHz. 

Next steps for this project:
- Finish detailing README and collect the UART streamed automata GIFs for comparison against reference models
- Transition the state buffers from LUT RAM to BRAM, saving 200 LUTs
- Expand the datapath from one cell per clock to increase speed



| <img width="922" height="450" alt="Screenshot 2026-09-21 at 3 18 17 PM" src="https://github.com/user-attachments/assets/96f3f262-42d8-47d3-a490-a04daa84a4e3" /> |
| --- |
| Figure 1: Simulation run in Vivado for the testbench `tb_ca_video_core.v`|
