/*
 * rectangular_array_ns_test.sv: NS (input-stationary) mode variant of
 * rectangular_array_os_test, using the wavefront feeder.
 *
 * Verifies that the NS dataflow produces the same correct GEMM result as
 * OS/WS for a 2-row × 3-column array with K=3.
 *
 * A = [[1,2,3],[4,5,6]]  B = [[1,2,3],[4,5,6],[7,8,9]]
 * Expected C = [[30,36,42],[66,81,96]]
 */

`timescale 1ns/1ns

`include "sa_processing_elem.sv"
`include "systolic_array.sv"
`include "sa_wavefront_feeder.sv"

module rectangular_array_ns_test();
    localparam int I_WORD_SIZE = 8;
    localparam int NUM_ROWS    = 2;
    localparam int K_DIM       = 3;
    localparam int NUM_COLS    = 3;
    localparam int O_WORD_SIZE = 2 * I_WORD_SIZE;

    logic clk;
    logic rst_l;
    logic i_acc_clear;
    logic feeder_start, feeder_done, feeder_busy;
    logic [NUM_ROWS - 1:0]    i_rowsValid;
    logic [NUM_COLS - 1:0]    i_colsValid;
    logic [I_WORD_SIZE - 1:0] i_cellData [NUM_ROWS + NUM_COLS];
    logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS];
    logic                     o_compDone;

    logic [I_WORD_SIZE - 1:0] i_matrixA [NUM_ROWS][K_DIM];
    logic [I_WORD_SIZE - 1:0] i_matrixB [K_DIM][NUM_COLS];

    sa_wavefront_feeder #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .K_DIM(K_DIM)
    ) feeder(
        .clk,
        .rst_l,
        .i_start(feeder_start),
        .i_k_dim('0),
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
        .NUM_COLS(NUM_COLS),
        .DATAFLOW_MODE(SA_DATAFLOW_NS)
    ) dut(
        .clk,
        .rst_l,
        .i_rowsValid,
        .i_colsValid,
        .i_cellData,
        .i_feederDone(feeder_done),
        .i_acc_clear,
        .o_cellData,
        .o_compDone
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    initial begin
        rst_l        <= 1'b0;
        i_acc_clear  <= 1'b0;
        feeder_start <= 1'b0;

        // A = [[1,2,3],[4,5,6]]
        i_matrixA[0][0] <= 8'd1; i_matrixA[0][1] <= 8'd2; i_matrixA[0][2] <= 8'd3;
        i_matrixA[1][0] <= 8'd4; i_matrixA[1][1] <= 8'd5; i_matrixA[1][2] <= 8'd6;

        // B = [[1,2,3],[4,5,6],[7,8,9]]
        i_matrixB[0][0] <= 8'd1; i_matrixB[0][1] <= 8'd2; i_matrixB[0][2] <= 8'd3;
        i_matrixB[1][0] <= 8'd4; i_matrixB[1][1] <= 8'd5; i_matrixB[1][2] <= 8'd6;
        i_matrixB[2][0] <= 8'd7; i_matrixB[2][1] <= 8'd8; i_matrixB[2][2] <= 8'd9;

        repeat (2) @(posedge clk);
        rst_l <= 1'b1;
        feeder_start <= 1'b1;
        @(posedge clk);
        feeder_start <= 1'b0;

        wait (o_compDone);
        @(posedge clk);

        $display("NS rect (2x3): row0=%0d %0d %0d  row1=%0d %0d %0d",
                 o_cellData[0][0], o_cellData[0][1], o_cellData[0][2],
                 o_cellData[1][0], o_cellData[1][1], o_cellData[1][2]);

        assert(o_cellData[0][0] == 8'd30);
        assert(o_cellData[0][1] == 8'd36);
        assert(o_cellData[0][2] == 8'd42);
        assert(o_cellData[1][0] == 8'd66);
        assert(o_cellData[1][1] == 8'd81);
        assert(o_cellData[1][2] == 8'd96);

        $display("RECTANGULAR ARRAY NS TEST PASSED");
        $finish;
    end
endmodule
