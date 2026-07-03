# Synthesizable Fixed-Point Mathematics Core (Q16.16)

A high-performance, resource-optimized fixed-point mathematics hardware IP core written in synthesizable Verilog. This core is specifically tailored for hardware acceleration, digital signal processing (DSP), and algorithmic computations in resource-constrained FPGAs and ASICs.

## Microarchitecture Features
- **Format:** Q16.16 fixed-point format (16-bit signed integer, 16-bit fractional component).
- **Fully Synthesizable:** Written in standard Verilog-2001, avoiding vendor-specific hard macros to ensure cross-platform compatibility.
- **Pipelined Architecture:** Optimized critical paths to achieve high maximum frequency ($F_{max}$) and maintain tight timing closures.
- **Deterministic Latency:** Single-clock cycle latency for basic arithmetic blocks, ensuring predictable execution bounds for real-time control loops.

## Target Hardware
Optimized primarily for **AMD Xilinx 7-Series FPGAs** (Artix-7, Kintex-7, Virtex-7) utilizing standard 6-input LUT microarchitectures.

### Estimated Resource Utilization (Artix-7 XC7A35T)
| Module | LUTs | Flip-Flops (FF) | DSP Slices | Latency (Cycles) |
| :--- | :--- | :--- | :--- | :--- |
| **FXP_Add** | ~32 | 0 | 0 | Combinatorial / 1 |
| **FXP_Sub** | ~32 | 0 | 0 | Combinatorial / 1 |
| **FXP_Mul** | ~48 | ~64 | 1 (DSP48E1) | 2 (Pipelined) |

## Directory Structure
```text
fixed-point-math-core/
├── rtl/
│   ├── fxp_add.v         # Fixed-point adder block
│   ├── fxp_sub.v         # Fixed-point subtractor block
│   └── fxp_mul.v         # Pipelined fixed-point multiplier
├── tb/
│   └── tb_fxp_math.v     # Comprehensive self-checking testbench
├── docs/                 # Additional design notes and timing diagrams
├── .gitignore            # Hardware tool-chain untracked files block
└── LICENSE               # MIT License
