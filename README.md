# Parametric Fixed-Point Arithmetic Core (ADD/SUB/MUL/DIV) for Xilinx Artix-7

A high-reliability, fully-clocked, signed fixed-point math IP core engineered in Verilog-2001 and verified with a robust SystemVerilog testbench. Designed specifically to hit high clock frequencies ($F_{\text{max}}$) and achieve clean timing closure on resource-constrained AMD Xilinx Artix-7 and 7-series FPGA fabric.

👉 **Looking for the Complete Production-Ready IP & Verification Package?**  
[Get Instant Access to the Full Design & Test Suite on Gumroad](https://vortexxip.gumroad.com/l/fixed-point-math-core)

---

## Why This Core? (The Engineering Edge)

Most standard Verilog math operations rely on behavioral operators (`*`, `/`) that synthesize into massive combinational paths or force the compiler to hog rigid, expensive DSP48E1 slices. 

This IP core solves that by utilizing an **architectural pipeline** optimized for physical implementation:
1. **Zero DSP Block Bloat**: Uses iterative shift-and-add (multiplication) and restoring shift-and-subtract (division) algorithms running at 1-bit/cycle. This keeps the combinational logic short, allowing synthesis to infer lightweight LUT/FF fabric.
2. **Timing-Closure Friendly**: Features a fully synchronous active-low reset layout (`rst_n`), isolating flip-flop resets locally and preventing heavy fan-in routing across global networks.
3. **Flexible Q-Format Precision**: Instantly scale your dynamic range via compile-time parameters (`TOTAL_WIDTH` and `FRACTIONAL_WIDTH`). Default configuration runs at an out-of-the-box signed **Q16.16** setup.

---

## Architectural Profile & Interface

### Latency Budget
- **ADD / SUB**: 2 clock cycles
- **MUL**: `TOTAL_WIDTH` + 2 cycles
- **DIV**: `TOTAL_WIDTH` + `FRACTIONAL_WIDTH` + 2 cycles

### Handshake Protocol
The core implements an industrial 3-wire handshake mechanism (`start`, `ready`, `valid`) to maximize data throughput and enable immediate, back-to-back operations.

---

## What’s Included in the Repository

- `fp_math_core.v` : Synthesizable RTL design implementing the full control FSM and iterative logic.
- `tb_fp_math_core.sv` : Self-checking behavioral verification testbench running randomized stress tests.

---

## Verification & Stress Testing

The design features a complete SystemVerilog verification suite (`tb_fp_math_core.sv`) which checks correctness against a floating-point real-number golden reference model.

The environment validates:
- Real-number precision tracking within a quantization-aware error margin.
- Crucial edge-case limits (Max Positive overflow, Min Negative underflow, Zero boundaries).
- Real-time hardware exception flags including **Division-by-Zero** safety traps.
- 60+ fully randomized stimulus transactions (`std::randomize()`) biased towards physical extreme thresholds.

### Running the Testbench
To compile and execute the simulation natively in your environment (e.g., Vivado XSIM, ModelSim):

```bash
vlog fp_math_core.v tb_fp_math_core.sv
vsim tb_fp_math_core -c -do "run -all; quit"
