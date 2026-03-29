/*
* single_pe_test.sv: Tests the top-left corner PE.
*
* Author: Albert Luo (albertlu)
*/

`timescale 1ns/1ns

`include "sa_processing_elem.sv"

module single_pe_test();
    localparam int I_WIDTH = 4;
    localparam int O_WIDTH = 8;

    logic                 clk, rst_l;
    logic                 i_valid, i_ready;
    logic [I_WIDTH - 1:0] i_rowData, i_colData;
    logic [O_WIDTH - 1:0] o_rowData, o_colData;

    sa_processing_elem #(.I_WORD_SIZE(I_WIDTH), .O_WORD_SIZE(O_WIDTH))
        PE(.*);

    initial begin
        clk   = 0;
        rst_l = 1;

        forever #10 clk = ~clk;
    end

    initial begin
        // Reset PE initially.
        rst_l <= 1'b0;
        i_valid <= 1'b0;
        i_ready <= 1'b0;
        @(posedge clk);

        rst_l <= 1'b1;
        i_valid <= 1'b1;
        i_ready <= 1'b1;
        i_rowData <= I_WIDTH'(4);
        i_colData <= I_WIDTH'(2);
        repeat (5) @(posedge clk);
        $finish;
    end
endmodule : single_pe_test
