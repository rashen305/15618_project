/*
* feeder_test.sv: Tests the functionality fo the wavefront feeder.
*
* Author: Albert Luo (albertlu)
*/

`timescale 1ns/1ns

`include "sa_wavefront_feeder.sv"
`include "sa_processing_elem.sv"
`include "systolic_array.sv"

module feeder_test();
    localparam int I_WORD_SIZE = 8;
    localparam int O_WORD_SIZE = 2 * I_WORD_SIZE;
    localparam int NUM_ROWS    = 2;
    localparam int K_DIM       = 3;
    localparam int NUM_COLS    = 2;

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

    initial begin
        rst_l <= 1'b0;
        feeder_start <= 1'b0;

        i_matrixA[0][0] <= I_WORD_SIZE'(1);
        i_matrixA[0][1] <= I_WORD_SIZE'(2);
        i_matrixA[0][2] <= I_WORD_SIZE'(3);
        i_matrixA[1][0] <= I_WORD_SIZE'(4);
        i_matrixA[1][1] <= I_WORD_SIZE'(5);
        i_matrixA[1][2] <= I_WORD_SIZE'(6);

        i_matrixB[0][0] <= I_WORD_SIZE'(9);
        i_matrixB[0][1] <= I_WORD_SIZE'(8);
        i_matrixB[1][0] <= I_WORD_SIZE'(7);
        i_matrixB[1][1] <= I_WORD_SIZE'(6);
        i_matrixB[2][0] <= I_WORD_SIZE'(5);
        i_matrixB[2][1] <= I_WORD_SIZE'(4);

        repeat (2) @(posedge clk);
        rst_l <= 1'b1;
        feeder_start <= 1'b1;
        @(posedge clk);
        feeder_start <= 1'b0;

        wait (o_compDone) begin
            @(posedge clk);
            FINAL_RESULT_ASSERT : begin
                assert(o_cellData[0][0] == 38);
                assert(o_cellData[0][1] == 32);
                assert(o_cellData[1][0] == 101);
                assert(o_cellData[1][1] == 86);
            end
        end

        $display("\n");
        $display("***************************************************************************");
        $display("                            ALL TESTS PASSED!                              ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : feeder_test
