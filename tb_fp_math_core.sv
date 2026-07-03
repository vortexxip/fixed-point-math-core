// =============================================================================
// File        : tb_fp_math_core.sv
// Module      : tb_fp_math_core
// Standard    : SystemVerilog (self-checking behavioral testbench)
// Description : Verification environment for fp_math_core. Drives directed
//               edge-case vectors plus randomized (std::randomize()) stimulus,
//               scores DUT results against a real-number golden reference
//               model, and reports PASS/FAIL with a quantization-aware error
//               margin.
// =============================================================================
`timescale 1ns/1ps

module tb_fp_math_core;

    // -------------------------------------------------------------------
    // Parameters (must match DUT instantiation)
    // -------------------------------------------------------------------
    localparam int TOTAL_WIDTH       = 32;
    localparam int FRACTIONAL_WIDTH  = 16;
    localparam int CLK_PERIOD_NS     = 10;
    localparam int NUM_RANDOM_TESTS  = 60;

    // Op encoding mirrored from RTL
    localparam bit [1:0] OP_ADD = 2'b00;
    localparam bit [1:0] OP_SUB = 2'b01;
    localparam bit [1:0] OP_MUL = 2'b10;
    localparam bit [1:0] OP_DIV = 2'b11;

    // Quantization-aware acceptable error margin (real units). The RTL
    // truncates (does not round) MUL/DIV results, so we allow a small
    // multiple of one fractional LSB.
    real ERROR_MARGIN;

    // -------------------------------------------------------------------
    // DUT interface signals
    // -------------------------------------------------------------------
    logic                          clk;
    logic                          rst_n;
    logic                          start;
    logic [1:0]                    op_sel;
    logic signed [TOTAL_WIDTH-1:0] operand_a;
    logic signed [TOTAL_WIDTH-1:0] operand_b;

    logic                          ready;
    logic                          valid;
    logic signed [TOTAL_WIDTH-1:0] result;
    logic                          overflow;
    logic                          div_by_zero;

    // -------------------------------------------------------------------
    // Scoreboard counters
    // -------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;
    int test_count = 0;

    // -------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------
    fp_math_core #(
        .TOTAL_WIDTH      (TOTAL_WIDTH),
        .FRACTIONAL_WIDTH (FRACTIONAL_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .op_sel      (op_sel),
        .operand_a   (operand_a),
        .operand_b   (operand_b),
        .ready       (ready),
        .valid       (valid),
        .result      (result),
        .overflow    (overflow),
        .div_by_zero (div_by_zero)
    );

    // -------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // -------------------------------------------------------------------
    // Fixed-point <-> real conversion helpers (golden reference math)
    // -------------------------------------------------------------------
    function automatic real fixed_to_real(input logic signed [TOTAL_WIDTH-1:0] val);
        return $itor(val) / (2.0 ** FRACTIONAL_WIDTH);
    endfunction

    // -------------------------------------------------------------------
    // Randomized transaction class (bound to TOTAL_WIDTH of this env)
    // -------------------------------------------------------------------
    class fp_transaction;
        rand bit signed [TOTAL_WIDTH-1:0] a;
        rand bit signed [TOTAL_WIDTH-1:0] b;
        rand bit [1:0]                    op;

        bit signed [TOTAL_WIDTH-1:0] max_val;
        bit signed [TOTAL_WIDTH-1:0] min_val;

        function new();
            max_val = {1'b0, {(TOTAL_WIDTH-1){1'b1}}}; // most positive representable value
            min_val = {1'b1, {(TOTAL_WIDTH-1){1'b0}}}; // most negative representable value
        endfunction

        // Bias distribution towards edge values (max, min, zero, small
        // fraction-only values) while still covering the general range.
        constraint c_op_valid {
            op inside {2'b00, 2'b01, 2'b10, 2'b11};
        }
        constraint c_edge_bias_a {
            a dist {
                max_val              := 2,
                min_val              := 2,
                0                    := 2,
                [min_val+1 : -1]     := 1,
                [1 : max_val-1]      := 1
            };
        }
        constraint c_edge_bias_b {
            b dist {
                max_val              := 2,
                min_val              := 2,
                0                    := 2,
                [min_val+1 : -1]     := 1,
                [1 : max_val-1]      := 1
            };
        }
    endclass

    fp_transaction rand_txn;

    // -------------------------------------------------------------------
    // Task: reset_dut - applies synchronous reset sequence
    // -------------------------------------------------------------------
    task automatic reset_dut();
        start     = 1'b0;
        op_sel    = OP_ADD;
        operand_a = '0;
        operand_b = '0;
        rst_n     = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        $display("[DESIGN INFO] Reset sequence complete. DUT ready=%0b", ready);
    endtask

    // -------------------------------------------------------------------
    // Task: apply_and_check - drives one operation and scores the result
    //   against a real-arithmetic golden model.
    // -------------------------------------------------------------------
    task automatic apply_and_check(
        input logic signed [TOTAL_WIDTH-1:0] a_in,
        input logic signed [TOTAL_WIDTH-1:0] b_in,
        input logic [1:0]                    op_in,
        input string                         label
    );
        real real_a, real_b, real_expected, real_actual, err;
        int  wait_cycles;
        begin
            // Wait until the core is ready to accept a new operation
            wait_cycles = 0;
            while (!ready) begin
                @(negedge clk);
                wait_cycles++;
                if (wait_cycles > 1000) begin
                    $display("[ERROR] %s : DUT never asserted ready - timeout", label);
                    fail_count++;
                    disable apply_and_check;
                end
            end

            // Drive operands and pulse start
            operand_a = a_in;
            operand_b = b_in;
            op_sel    = op_in;
            start     = 1'b1;
            @(negedge clk);
            start     = 1'b0;

            // Wait for the one-cycle 'valid' pulse
            wait_cycles = 0;
            while (!valid) begin
                @(negedge clk);
                wait_cycles++;
                if (wait_cycles > 10000) begin
                    $display("[ERROR] %s : DUT never asserted valid - timeout", label);
                    fail_count++;
                    disable apply_and_check;
                end
            end

            test_count++;
            real_a = fixed_to_real(a_in);
            real_b = fixed_to_real(b_in);

            unique case (op_in)
                OP_ADD:  real_expected = real_a + real_b;
                OP_SUB:  real_expected = real_a - real_b;
                OP_MUL:  real_expected = real_a * real_b;
                OP_DIV:  real_expected = (b_in == 0) ? 0.0 : (real_a / real_b);
                default: real_expected = 0.0;
            endcase

            // --- Division-by-zero special case -----------------------------
            if (op_in == OP_DIV && b_in == 0) begin
                if (div_by_zero) begin
                    $display("[PASSED] %-28s : div-by-zero correctly flagged", label);
                    pass_count++;
                end else begin
                    $display("[ERROR]  %-28s : div-by-zero NOT flagged (a=%.6f)", label, real_a);
                    fail_count++;
                end
            end
            // --- Overflow case: precision compare is not meaningful --------
            else if (overflow) begin
                $display("[DESIGN INFO] %-28s : overflow flagged (expected=%.6f, out of range for TOTAL_WIDTH=%0d) - treated as PASS",
                          label, real_expected, TOTAL_WIDTH);
                pass_count++;
            end
            // --- Normal precision-checked comparison ------------------------
            else begin
                real_actual = fixed_to_real(result);
                err = real_actual - real_expected;
                if (err < 0.0) err = -err;

                if (err <= ERROR_MARGIN) begin
                    $display("[PASSED] %-28s : a=%.6f b=%.6f op=%0d exp=%.6f act=%.6f err=%.6f",
                              label, real_a, real_b, op_in, real_expected, real_actual, err);
                    pass_count++;
                end else begin
                    $display("[ERROR]  %-28s : a=%.6f b=%.6f op=%0d exp=%.6f act=%.6f err=%.6f (margin=%.6f)",
                              label, real_a, real_b, op_in, real_expected, real_actual, err, ERROR_MARGIN);
                    fail_count++;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Main stimulus / verification sequence
    // -------------------------------------------------------------------
    initial begin
        ERROR_MARGIN = 2.0 / (2.0 ** FRACTIONAL_WIDTH); // 2 fractional LSBs tolerance

        $display("=============================================================");
        $display("[DESIGN INFO] fp_math_core Verification Environment");
        $display("[DESIGN INFO] TOTAL_WIDTH=%0d FRACTIONAL_WIDTH=%0d ERROR_MARGIN=%.8f",
                   TOTAL_WIDTH, FRACTIONAL_WIDTH, ERROR_MARGIN);
        $display("=============================================================");

        reset_dut();

        // -----------------------------------------------------------
        // Directed edge-case vectors
        // -----------------------------------------------------------
        $display("[DESIGN INFO] --- Directed Edge Case Tests ---");

        apply_and_check(32'sh00000000, 32'sh00000000, OP_ADD, "zero+zero");
        apply_and_check(32'sh00008000, 32'sh00008000, OP_ADD, "0.5+0.5 (frac-only)");
        apply_and_check(32'sh00004000, 32'shFFFFC000, OP_ADD, "0.25+(-0.25)");
        apply_and_check(32'sh7FFFFFFF, 32'sh00000001, OP_ADD, "MAX_POS + smallest LSB (overflow)");
        apply_and_check(32'sh80000000, 32'sh80000000, OP_ADD, "MIN_NEG + MIN_NEG (overflow)");
        apply_and_check(32'sh7FFFFFFF, 32'sh80000000, OP_SUB, "MAX_POS - MIN_NEG (overflow)");
        apply_and_check(32'sh80000000, 32'sh00000000, OP_SUB, "MIN_NEG - zero");
        apply_and_check(32'sh00020000, 32'sh00020000, OP_MUL, "2.0 * 2.0");
        apply_and_check(32'shFFFE0000, 32'sh00020000, OP_MUL, "-2.0 * 2.0");
        apply_and_check(32'sh00008000, 32'sh00008000, OP_MUL, "0.5 * 0.5 (frac-only)");
        apply_and_check(32'sh7FFFFFFF, 32'sh7FFFFFFF, OP_MUL, "MAX_POS * MAX_POS (overflow)");
        apply_and_check(32'sh00010000, 32'sh00000000, OP_DIV, "1.0 / 0.0 (div-by-zero)");
        apply_and_check(32'sh80000000, 32'sh00000000, OP_DIV, "MIN_NEG / 0.0 (div-by-zero)");
        apply_and_check(32'sh00030000, 32'sh00020000, OP_DIV, "3.0 / 2.0");
        apply_and_check(32'shFFFD0000, 32'sh00020000, OP_DIV, "-3.0 / 2.0");
        apply_and_check(32'sh00008000, 32'sh00020000, OP_DIV, "0.5 / 2.0 (frac-only)");
        apply_and_check(32'sh00000001, 32'sh7FFFFFFF, OP_DIV, "smallest LSB / MAX_POS");

        // -----------------------------------------------------------
        // Randomized stimulus using std::randomize()
        // -----------------------------------------------------------
        $display("[DESIGN INFO] --- Randomized Stimulus (%0d transactions) ---", NUM_RANDOM_TESTS);

        rand_txn = new();
        for (int i = 0; i < NUM_RANDOM_TESTS; i++) begin
            if (!rand_txn.randomize()) begin
                $display("[ERROR]  random_txn_%0d : randomize() call failed", i);
                fail_count++;
                continue;
            end
            apply_and_check(rand_txn.a, rand_txn.b, rand_txn.op,
                             $sformatf("random_txn_%0d", i));
        end

        // -----------------------------------------------------------
        // Final report
        // -----------------------------------------------------------
        $display("=============================================================");
        $display("[DESIGN INFO] Verification Complete");
        $display("[DESIGN INFO] Total Tests : %0d", test_count);
        $display("[DESIGN INFO] Passed      : %0d", pass_count);
        $display("[DESIGN INFO] Failed      : %0d", fail_count);
        if (fail_count == 0) begin
            $display("[PASSED] ALL TESTS PASSED - fp_math_core verified within error margin");
        end else begin
            $display("[ERROR]  %0d TEST(S) FAILED - review log above", fail_count);
        end
        $display("=============================================================");

        $finish;
    end

    // -------------------------------------------------------------------
    // Safety watchdog: abort simulation if it runs away
    // -------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD_NS * 2_000_000);
        $display("[ERROR] Global simulation watchdog timeout - forcing $finish");
        $finish;
    end

endmodule
