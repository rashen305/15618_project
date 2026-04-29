/*
* single_pe_test.sv: Basic self-check for one processing element.
*/

`timescale 1ns/1ns

`include "sa_processing_elem.sv"

module single_pe_test();
    localparam int I_WIDTH = 8;
    localparam int O_WIDTH = 32;

    logic clk;
    logic rst_l;
    logic i_rowValid;
    logic i_colValid;
    logic i_acc_clear;
    logic [I_WIDTH - 1:0] i_rowData;
    logic [I_WIDTH - 1:0] i_colData;
    logic o_rowValid;
    logic o_colValid;
    logic [I_WIDTH - 1:0] o_rowData;
    logic [I_WIDTH - 1:0] o_colData;
    logic [O_WIDTH - 1:0] o_accData;

    logic [O_WIDTH - 1:0] golden;

    sa_processing_elem #(
        .I_WORD_SIZE(I_WIDTH),
        .O_WORD_SIZE(O_WIDTH)
    ) dut (
        .*
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    initial begin
        rst_l       <= 1'b0;
        i_rowValid  <= 1'b0;
        i_colValid  <= 1'b0;
        i_acc_clear <= 1'b1;
        i_rowData   <= '0;
        i_colData   <= '0;
        golden      <= '0;

        repeat (2) @(posedge clk);
        rst_l       <= 1'b1;
        i_acc_clear <= 1'b0;

        for (int i = 0; i < 8; i++) begin
            @(negedge clk);
            i_rowValid <= 1'b1;
            i_colValid <= 1'b1;
            i_rowData  <= I_WIDTH'(i + 1);
            i_colData  <= I_WIDTH'(i + 2);

            @(posedge clk);
            assert(o_accData == golden)
                else $fatal(1, "Expected PE accumulator %0d, got %0d.", golden, o_accData);
            golden <= golden + ((i + 1) * (i + 2));
        end

        @(negedge clk);
        i_rowValid  <= 1'b0;
        i_colValid  <= 1'b0;
        i_acc_clear <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        assert(o_accData == '0) else $fatal(1, "Expected PE accumulator clear.");

        $display("\n");
        $display("***************************************************************************");
        $display("                            PE TESTS PASSED                                ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : single_pe_test
