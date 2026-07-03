// =============================================================================
// File        : fp_math_core.v
// Module      : fp_math_core
// Standard    : Verilog-2001
// Description : Parametrized, fully-clocked fixed-point arithmetic core
//               (ADD / SUB / MUL / DIV) targeting AMD Xilinx Artix-7.
//
// Design Notes (Fmax / Resource Rationale):
//   - Synchronous, active-low reset is used (not asynchronous) to avoid
//     routing resets through the dedicated global reset network and to keep
//     the FF reset fan-in local, which improves timing closure on 7-series
//     fabric.
//   - Multiplication uses an iterative shift-and-add sequential multiplier
//     (1 bit/cycle) instead of a single-cycle combinational '*' operator.
//     This keeps the combinational path short (a single adder stage) and
//     lets synthesis infer plain LUT/FF logic rather than forcing DSP48E1
//     usage, at the cost of TOTAL_WIDTH cycles of latency.
//   - Division uses a classic iterative restoring shift-and-subtract
//     algorithm (1 quotient bit/cycle), entirely avoiding the behavioral
//     '/' operator, which would otherwise synthesize into a large
//     combinational (or vendor IP) divider.
//   - All arithmetic is performed on sign-magnitude operands internally to
//     keep the iterative datapaths (multiplier/divider) simple unsigned
//     structures; the sign is re-applied at the end.
//
// Fixed-Point Format:
//   Signed Q(TOTAL_WIDTH-FRACTIONAL_WIDTH).(FRACTIONAL_WIDTH), two's
//   complement, MSB = sign bit.
//
// Operation Encoding (op_sel):
//   2'b00 = ADD   2'b01 = SUB   2'b10 = MUL   2'b11 = DIV
//
// Handshake:
//   - Assert 'start' for one cycle while 'ready' is high to launch an
//     operation. Operands must be valid on the same cycle as 'start'.
//   - 'ready' deasserts while the core is busy.
//   - 'valid' pulses high for exactly one cycle when 'result' (and the
//     'overflow' / 'div_by_zero' flags) are valid. 'ready' reasserts on the
//     same cycle so a back-to-back operation can be launched immediately.
//
// Latency (approximate, cycles from start to valid):
//   ADD/SUB : 2
//   MUL     : TOTAL_WIDTH + 2
//   DIV     : TOTAL_WIDTH + FRACTIONAL_WIDTH + 2
// =============================================================================

module fp_math_core #(
    parameter TOTAL_WIDTH      = 32,   // Total bit width of operands/result
    parameter FRACTIONAL_WIDTH = 16    // Number of fractional bits (Q format)
)(
    input  wire                          clk,          // System clock
    input  wire                          rst_n,         // Synchronous active-low reset
    input  wire                          start,         // Pulse high to launch an operation
    input  wire [1:0]                    op_sel,        // 00=ADD 01=SUB 10=MUL 11=DIV
    input  wire signed [TOTAL_WIDTH-1:0] operand_a,     // Signed fixed-point operand A
    input  wire signed [TOTAL_WIDTH-1:0] operand_b,     // Signed fixed-point operand B

    output reg                           ready,         // High when core can accept a new 'start'
    output reg                           valid,         // One-cycle pulse: 'result' is valid
    output reg  signed [TOTAL_WIDTH-1:0] result,        // Signed fixed-point result
    output reg                           overflow,      // Result magnitude exceeded TOTAL_WIDTH range
    output reg                           div_by_zero    // DIV operation attempted with operand_b == 0
);

    // -------------------------------------------------------------------
    // Derived constants
    // -------------------------------------------------------------------
    localparam integer DIV_WIDTH = TOTAL_WIDTH + FRACTIONAL_WIDTH; // Quotient width for division
    // NOTE: $clog2 is used here as a synthesis-time constant-function extension
    // (supported by Vivado/XST for Verilog-2001 sources) purely to right-size
    // the iteration counters and minimize FF usage.
    localparam integer MUL_CNT_W = $clog2(TOTAL_WIDTH + 1);
    localparam integer DIV_CNT_W = $clog2(DIV_WIDTH + 1);

    // Operation encoding
    localparam [1:0] OP_ADD = 2'b00;
    localparam [1:0] OP_SUB = 2'b01;
    localparam [1:0] OP_MUL = 2'b10;
    localparam [1:0] OP_DIV = 2'b11;

    // FSM state encoding
    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_ADDSUB   = 3'd1;
    localparam [2:0] ST_MUL_INIT = 3'd2;
    localparam [2:0] ST_MUL_RUN  = 3'd3;
    localparam [2:0] ST_DIV_INIT = 3'd4;
    localparam [2:0] ST_DIV_RUN  = 3'd5;
    localparam [2:0] ST_FINISH   = 3'd6;

    // -------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------
    reg [2:0] state;                          // Main FSM state register

    reg                          op_reg;       // (unused placeholder removed below)
    reg [1:0]                    op_r;         // Latched operation select
    reg signed [TOTAL_WIDTH-1:0] a_reg, b_reg; // Latched raw signed operands (for ADD/SUB)

    reg sign_a, sign_b, sign_res;              // Latched operand signs / computed result sign
    reg [TOTAL_WIDTH-1:0] mag_a, mag_b;        // Sign-magnitude representations of operands

    // Multiplier datapath (iterative shift-and-add)
    reg [2*TOTAL_WIDTH-1:0] mul_acc;           // Product accumulator
    reg [2*TOTAL_WIDTH-1:0] mul_cand;          // Shifting multiplicand
    reg [TOTAL_WIDTH-1:0]   mul_mplier;        // Shifting multiplier (test LSB each cycle)
    reg [MUL_CNT_W-1:0]     mul_cnt;           // Remaining multiplier iterations

    // Divider datapath (iterative restoring shift-and-subtract)
    reg [DIV_WIDTH:0]   div_rem;               // Remainder register (extra guard bit)
    reg [DIV_WIDTH-1:0] div_quo;               // Quotient / numerator shift register
    reg [DIV_WIDTH:0]   div_den_ext;           // Zero-extended divisor
    reg [DIV_CNT_W-1:0] div_cnt;               // Remaining divider iterations

    // Combinational scratch registers (intra-cycle temporaries, blocking-assigned)
    reg [DIV_WIDTH:0]   shifted_rem;
    reg [DIV_WIDTH-1:0] shifted_quo;
    reg [DIV_WIDTH:0]   trial;
    reg [2*TOTAL_WIDTH-1:0] shifted_prod;
    reg signed [TOTAL_WIDTH:0] ext_result;
    reg ovf_mul, ovf_div;

    // -------------------------------------------------------------------
    // Main synchronous FSM
    // -------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            // Synchronous reset: clear all state/output registers
            state       <= ST_IDLE;
            ready       <= 1'b1;
            valid       <= 1'b0;
            result      <= {TOTAL_WIDTH{1'b0}};
            overflow    <= 1'b0;
            div_by_zero <= 1'b0;

            op_r   <= 2'b00;
            a_reg  <= {TOTAL_WIDTH{1'b0}};
            b_reg  <= {TOTAL_WIDTH{1'b0}};
            sign_a <= 1'b0;
            sign_b <= 1'b0;
            sign_res <= 1'b0;
            mag_a  <= {TOTAL_WIDTH{1'b0}};
            mag_b  <= {TOTAL_WIDTH{1'b0}};

            mul_acc    <= {(2*TOTAL_WIDTH){1'b0}};
            mul_cand   <= {(2*TOTAL_WIDTH){1'b0}};
            mul_mplier <= {TOTAL_WIDTH{1'b0}};
            mul_cnt    <= {MUL_CNT_W{1'b0}};

            div_rem     <= {(DIV_WIDTH+1){1'b0}};
            div_quo     <= {DIV_WIDTH{1'b0}};
            div_den_ext <= {(DIV_WIDTH+1){1'b0}};
            div_cnt     <= {DIV_CNT_W{1'b0}};

        end else begin
            // Default: 'valid' is a single-cycle pulse, deassert unless
            // explicitly asserted in ST_FINISH below.
            valid <= 1'b0;

            case (state)

                // -------------------------------------------------------
                // ST_IDLE: wait for 'start', latch operands, dispatch op
                // -------------------------------------------------------
                ST_IDLE: begin
                    ready <= 1'b1;
                    if (start) begin
                        ready       <= 1'b0;
                        overflow    <= 1'b0;
                        div_by_zero <= 1'b0;

                        op_r  <= op_sel;
                        a_reg <= operand_a;
                        b_reg <= operand_b;

                        sign_a <= operand_a[TOTAL_WIDTH-1];
                        sign_b <= operand_b[TOTAL_WIDTH-1];
                        // Convert to sign-magnitude for MUL/DIV datapaths
                        mag_a  <= operand_a[TOTAL_WIDTH-1] ? (~operand_a + 1'b1) : operand_a;
                        mag_b  <= operand_b[TOTAL_WIDTH-1] ? (~operand_b + 1'b1) : operand_b;

                        case (op_sel)
                            OP_ADD:  state <= ST_ADDSUB;
                            OP_SUB:  state <= ST_ADDSUB;
                            OP_MUL:  state <= ST_MUL_INIT;
                            OP_DIV:  state <= ST_DIV_INIT;
                            default: state <= ST_IDLE;
                        endcase
                    end
                end

                // -------------------------------------------------------
                // ST_ADDSUB: single-cycle signed add/sub with overflow chk
                // -------------------------------------------------------
                ST_ADDSUB: begin
                    if (op_r == OP_SUB)
                        ext_result = {a_reg[TOTAL_WIDTH-1], a_reg} - {b_reg[TOTAL_WIDTH-1], b_reg};
                    else
                        ext_result = {a_reg[TOTAL_WIDTH-1], a_reg} + {b_reg[TOTAL_WIDTH-1], b_reg};

                    // Overflow if the guard bit disagrees with the sign bit of the result
                    overflow <= (ext_result[TOTAL_WIDTH] != ext_result[TOTAL_WIDTH-1]);
                    result   <= ext_result[TOTAL_WIDTH-1:0];
                    state    <= ST_FINISH;
                end

                // -------------------------------------------------------
                // ST_MUL_INIT: load sequential shift-and-add multiplier
                // -------------------------------------------------------
                ST_MUL_INIT: begin
                    mul_acc    <= {(2*TOTAL_WIDTH){1'b0}};
                    mul_cand   <= {{TOTAL_WIDTH{1'b0}}, mag_a};
                    mul_mplier <= mag_b;
                    mul_cnt    <= TOTAL_WIDTH[MUL_CNT_W-1:0];
                    sign_res   <= sign_a ^ sign_b;
                    state      <= ST_MUL_RUN;
                end

                // -------------------------------------------------------
                // ST_MUL_RUN: 1 bit/cycle shift-and-add multiplication
                // -------------------------------------------------------
                ST_MUL_RUN: begin
                    if (mul_mplier[0])
                        mul_acc <= mul_acc + mul_cand;
                    mul_cand   <= mul_cand << 1;
                    mul_mplier <= mul_mplier >> 1;

                    if (mul_cnt == {{(MUL_CNT_W-1){1'b0}}, 1'b1}) begin
                        state <= ST_FINISH;
                    end else begin
                        mul_cnt <= mul_cnt - 1'b1;
                    end
                end

                // -------------------------------------------------------
                // ST_DIV_INIT: load restoring shift-and-subtract divider
                // -------------------------------------------------------
                ST_DIV_INIT: begin
                    sign_res <= sign_a ^ sign_b;
                    if (mag_b == {TOTAL_WIDTH{1'b0}}) begin
                        div_by_zero <= 1'b1;
                        state       <= ST_FINISH;
                    end else begin
                        div_rem     <= {(DIV_WIDTH+1){1'b0}};
                        // Numerator pre-shifted left by FRACTIONAL_WIDTH to preserve fraction bits
                        div_quo     <= {mag_a, {FRACTIONAL_WIDTH{1'b0}}};
                        div_den_ext <= {1'b0, {FRACTIONAL_WIDTH{1'b0}}, mag_b};
                        div_cnt     <= DIV_WIDTH[DIV_CNT_W-1:0];
                        state       <= ST_DIV_RUN;
                    end
                end

                // -------------------------------------------------------
                // ST_DIV_RUN: 1 quotient bit/cycle restoring division
                // -------------------------------------------------------
                ST_DIV_RUN: begin
                    shifted_rem = {div_rem[DIV_WIDTH-1:0], div_quo[DIV_WIDTH-1]};
                    shifted_quo = {div_quo[DIV_WIDTH-2:0], 1'b0};
                    trial       = shifted_rem - div_den_ext;

                    if (trial[DIV_WIDTH]) begin
                        // Borrow occurred: restore remainder, quotient bit = 0
                        div_rem <= shifted_rem;
                        div_quo <= shifted_quo;
                    end else begin
                        // No borrow: keep subtracted remainder, quotient bit = 1
                        div_rem <= trial;
                        div_quo <= shifted_quo | {{(DIV_WIDTH-1){1'b0}}, 1'b1};
                    end

                    if (div_cnt == {{(DIV_CNT_W-1){1'b0}}, 1'b1}) begin
                        state <= ST_FINISH;
                    end else begin
                        div_cnt <= div_cnt - 1'b1;
                    end
                end

                // -------------------------------------------------------
                // ST_FINISH: apply sign, detect overflow, publish result
                // -------------------------------------------------------
                ST_FINISH: begin
                    ready <= 1'b1;
                    valid <= 1'b1;

                    case (op_r)
                        OP_MUL: begin
                            shifted_prod = mul_acc >> FRACTIONAL_WIDTH;
                            // Overflow: bits above TOTAL_WIDTH are non-zero, or a
                            // positive result would clobber the sign bit.
                            ovf_mul = |shifted_prod[2*TOTAL_WIDTH-1:TOTAL_WIDTH] |
                                      (~sign_res & shifted_prod[TOTAL_WIDTH-1]);
                            overflow <= ovf_mul;
                            result   <= sign_res ? (~shifted_prod[TOTAL_WIDTH-1:0] + 1'b1)
                                                  :   shifted_prod[TOTAL_WIDTH-1:0];
                        end

                        OP_DIV: begin
                            if (div_by_zero) begin
                                result <= {TOTAL_WIDTH{1'b0}};
                            end else begin
                                ovf_div = |div_quo[DIV_WIDTH-1:TOTAL_WIDTH] |
                                          (~sign_res & div_quo[TOTAL_WIDTH-1]);
                                overflow <= ovf_div;
                                result   <= sign_res ? (~div_quo[TOTAL_WIDTH-1:0] + 1'b1)
                                                      :   div_quo[TOTAL_WIDTH-1:0];
                            end
                        end

                        default: begin
                            // ADD/SUB result already finalized in ST_ADDSUB
                        end
                    endcase

                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
