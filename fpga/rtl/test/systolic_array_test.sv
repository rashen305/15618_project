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

    task automatic clearInputs();
        i_rowsValid <= '0;
        i_colsValid <= '0;

        for (int i = 0; i < NUM_ROWS + NUM_COLS; i++) begin
            i_cellData[i] <= '0;
        end
    endtask : clearInputs

    task automatic driveCycle(
        input  logic [NUM_ROWS - 1:0] rowsValid,
        input  logic [NUM_ROWS - 1:0] colsValid,
        input  logic [I_WORD_SIZE - 1:0] col0Data,
        input  logic [I_WORD_SIZE - 1:0] col1Data,
        input  logic [I_WORD_SIZE - 1:0] row0Data,
        input  logic [I_WORD_SIZE - 1:0] row1Data
    );

        @(negedge clk);
        i_rowsValid <= rowsValid;
        i_colsValid <= colsValid;
        i_cellData[0] <= col0Data;
        i_cellData[1] <= col1Data;
        i_cellData[2] <= row0Data;
        i_cellData[3] <= row1Data;
    endtask : driveCycle

    initial begin
        rst_l <= 1'b0;
        @(posedge clk);
        rst_l <= 1'b1;

        clearInputs();

        driveCycle(
            2'b01,
            2'b01,
            8'd5,
            8'd0,
            8'd1,
            8'd0
        );

        driveCycle(
            2'b11,
            2'b11,
            8'd7,
            8'd6,
            8'd2,
            8'd3
        );

        driveCycle(
            2'b10,
            2'b10,
            8'd0,
            8'd8,
            8'd0,
            8'd4
        );

        @(posedge clk);

        driveCycle(
            2'b00,
            2'b00,
            8'd0,
            8'd0,
            8'd0,
            8'd0
        );

        wait (o_compDone) begin
            @(posedge clk);
            FINAL_RESULT_ASSERT : begin
                assert(o_cellData[0][0] == 19);
                assert(o_cellData[0][1] == 22);
                assert(o_cellData[1][0] == 43);
                assert(o_cellData[1][1] == 50);
            end

        end

        $display("\n");
        $display("***************************************************************************");
        $display("                            ALL TESTS PASSED!                              ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : systolic_array_test
