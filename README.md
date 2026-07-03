# Fixed-Point Math Core

A parametrized, fully-clocked signed fixed-point arithmetic core designed in Verilog-2001, complete with a self-checking SystemVerilog verification testbench. This design is optimized for AMD Xilinx Artix-7 FPGA fabric, prioritizing low resource usage and clean timing closure.

## Features

- **Parametrizable Widths**: Fully dynamic parameters for total bit width (`TOTAL_WIDTH`) and fractional precision bits (`FRACTIONAL_WIDTH`). Default configuration runs at standard signed Q16.16 format.
- **Supported Operations**: 
  - `2'b00` : ADD (Addition)
  - `2'b01` : SUB (Subtraction)
  - `2'b10` : MUL (Multiplication via iterative shift-and-add)
  - `2'b11` : DIV (Division via iterative restoring shift-and-subtract)
- **Hardware Optimization**: 
  - Uses a **synchronous active-low reset** (`rst_n`) to stay local to Logic Elements and optimize placement routing without straining the global reset network.
  - Multiplier and Divider execute at **1 bit per cycle**, eliminating large combinational depth or the need to infer rigid dedicated DSP48E1 blocks.
- **Handshake Protocol**: Controlled via structural `start`, `ready`, and `valid` control lines. 

## Architectural Latency

- **ADD / SUB**: 2 cycles
- **MUL**: `TOTAL_WIDTH` + 2 cycles
- **DIV**: `TOTAL_WIDTH` + `FRACTIONAL_WIDTH` + 2 cycles

## Project Structure

- `fp_math_core.v` : Core synthesizable RTL implementation.
- `tb_fp_math_core.sv` : Comprehensive verification environment driving edge-case diagnostics and randomized testing sequences (`std::randomize()`) scored against a real-number floating-point reference model.

## Simulation & Verification

The self-checking testbench applies a quantization-aware margin of tolerance ($2 \times \text{fractional LSBs}$) to validate execution results. It tests:
1. Directed boundary/edge cases (Zeros, Overflow limits, Min/Max thresholds).
2. Division-by-zero hardware exception flags.
3. 60+ fully randomized transactions.

### How to Run Simulation

Compile and simulate using any standard SystemVerilog simulator (e.g., Vivado XSIM, ModelSim, Verilator):

```bash
# Example compilation command using standard tools (adjust to your specific vendor CLI)
vlog fp_math_core.v tb_fp_math_core.sv
vsim tb_fp_math_core -c -do "run -all; quit"
