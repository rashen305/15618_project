/*
* systolic_array_test.sv: Tests the functionality of the NSSA (for now).
*
* Author: Albert Luo (albertlu)
*/

`timescale 1ns/1ns

`include "sa_processing_elem.sv"
`include "systolic_array.sv"

module systolic_array_test();
    localparam int I_WORD_SIZE = 8;
    localparam int O_WORD_SIZE = 2 * I_WORD_SIZE;
    localparam int NUM_ROWS    = 2;
    localparam int NUM_COLS    = 2;

     logic clk;
     logic rst_l;
     logic [NUM_ROWS - 1:0]    i_rowsValid;
     logic [NUM_COLS - 1:0]    i_colsValid;
     logic [I_WORD_SIZE - 1:0] i_cellData [NUM_ROWS + NUM_COLS];
     logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS];
     logic                     o_compDone;
     logic [O_WORD_SIZE - 1:0] o_accData;

    ns_systolic_array #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS)
    )
        systolicArray_DUT(.*);

    // Clocking block.
    initial begin
        clk   = 0;
        rst_l = 1;

        forever #10 clk = ~clk;
    end

    initial begin
        // Reset the entire systolic array.
        @(posedge clk) begin
            rst_l <= 1'b0;
            i_rowsValid <= '0;
            i_colsValid <= '0;

            for (int i = 0; i < NUM_ROWS + NUM_COLS; i++) begin
                i_cellData[i] <= '0;
            end
        end

        repeat (2) @(posedge clk);

        // Cycle 1 injection.
        @(posedge clk) begin
            i_colsValid <= 2'b11;
            i_rowsValid <= 2'b11;

            i_cellData[0] <= 5;
            i_cellData[1] <= 6;
            i_cellData[2] <= 1;
            i_cellData[3] <= 3;
        end

        // Cycle 2 injection.
        @(posedge clk) begin
            i_colsValid <= 2'b11;
            i_rowsValid <= 2'b11;

            i_cellData[0] <= 7;
            i_cellData[1] <= 8;
            i_cellData[2] <= 2;
            i_cellData[3] <= 4;
        end

        // Stop injecting.
        @(posedge clk) begin
            i_colsValid <= '0;
            i_rowsValid <= '0;

            for (int i = 0; i < NUM_ROWS + NUM_COLS; i++) begin
                i_cellData[i] = '0;
            end
        end

        repeat (6) @(posedge clk);

        $display("\n");
        $display("***************************************************************************");
        $display("                            ALL TESTS PASSED!                              ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : systolic_array_test
