/*
* sa_stress_test.sv: Runs stress testing on systolic arrays of different sizes
*                    for functionality and timing.
*
* Author: Albert Luo (albertlu)
*/

`timescale 1ns/1ns

`include "sa_wavefront_feeder.sv"
`include "sa_processing_elem.sv"
`include "systolic_array.sv"
`include "sa_params.sv"

module sa_stress_test #(
      parameter int I_WORD_SIZE = MATRIX_WORD_SIZE,
      parameter int NUM_ROWS    = SA_ROWS,
      parameter int NUM_COLS    = SA_COLS,
      parameter int K_DIM       = NUM_ROWS,
      parameter int VALUE_MAX   = 10,
      parameter int NUM_TESTS   = 10,
      parameter int TEST_ID     = 0
)(
      output logic o_done,
      output logic o_pass
);

    localparam int O_WORD_SIZE = 2 * I_WORD_SIZE;

    logic clk;
    logic rst_l;
    logic [NUM_ROWS - 1:0]    i_rowsValid;
    logic [NUM_COLS - 1:0]    i_colsValid;
    logic [I_WORD_SIZE - 1:0] i_cellData [NUM_ROWS + NUM_COLS];
    logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS];
    logic                     o_compDone;
    logic [O_WORD_SIZE - 1:0] o_accData;

    logic [I_WORD_SIZE - 1:0] i_matrixA [NUM_ROWS][K_DIM];
    logic [I_WORD_SIZE - 1:0] i_matrixB [K_DIM][NUM_COLS];

    logic                     feeder_start, feeder_busy, feeder_done;

    logic [O_WORD_SIZE - 1:0] expectedC [NUM_ROWS][NUM_COLS];

    integer                   test_idx;

    sa_wavefront_feeder #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .K_DIM(K_DIM)
    ) feeder(
        .clk,
        .rst_l,
        .i_start(feeder_start),
        .i_matrixA,
        .i_matrixB,
        .o_rowsValid(i_rowsValid),
        .o_colsValid(i_colsValid),
        .o_cellData(i_cellData),
        .o_busy(feeder_busy),
        .o_done(feeder_done)
    );

    ns_systolic_array #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS)
    ) systolicArray_DUT(
        .i_feederDone(feeder_done),
        .*
    );

    // Clocking block.
    initial begin
        clk   = 0;
        rst_l = 1;

        forever #10 clk = ~clk;
    end

    task automatic clear_mats();
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int k = 0; k < NUM_COLS; k++) begin
                i_matrixA[r][k] = '0;
            end
        end

        for (int k = 0; k < K_DIM; k++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                i_matrixB[k][c] = '0;
            end
        end
    endtask

    task automatic reset_case();
        rst_l <= 1'b0;
        feeder_start <= 1'b0;
        clear_mats();
        repeat (2) @(posedge clk);
        rst_l <= 1'b1;
        @(posedge clk);
    endtask

    task automatic randomize_mats(input int value_max);
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int k = 0; k < K_DIM; k++) begin
                i_matrixA[r][k] = I_WORD_SIZE'($urandom_range(0, value_max));
            end
        end

        for (int k = 0; k < K_DIM; k++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                i_matrixB[k][c] = I_WORD_SIZE'($urandom_range(0, value_max));
            end
        end
    endtask

    task automatic compute_golden();
        logic [O_WORD_SIZE - 1:0] sum;

        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                sum = '0;

                for (int k = 0; k < K_DIM; k++) begin
                    sum += (i_matrixA[r][k] * i_matrixB[k][c]);
                end

                expectedC[r][c] = sum;
            end
        end
    endtask

    task automatic start_feeder();
        @(posedge clk);
        feeder_start <= 1'b1;
        @(posedge clk);
        feeder_start <= 1'b0;
    endtask

    task automatic check_outputs();
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                if (o_cellData[r][c] !== expectedC[r][c]) begin
                    o_pass = 1'b0;
                    o_done = 1'b1;

                    disable run_all_tests;
                end
            end
        end
    endtask

    initial begin : run_all_tests
        o_done <= 1'b0;
        o_pass <= 1'b1;

        reset_case();

        for (test_idx = 0; test_idx < NUM_TESTS; test_idx++) begin
            reset_case();
            randomize_mats(VALUE_MAX);
            compute_golden();
            start_feeder();

            wait (o_compDone);
            @(posedge clk);

            check_outputs();
        end

        o_done <= 1'b1;
    end
endmodule : sa_stress_test

module feeder_sweep();
    logic o_done, o_pass;

    sa_stress_test #(.NUM_ROWS(100), .NUM_COLS(1)) test(.o_done, .o_pass);

    initial begin
        wait (o_done);

        if (o_pass) begin
            $display("pass.");
        end

        else begin
            $display("trash.");
        end
        $finish;
    end
endmodule : feeder_sweep
