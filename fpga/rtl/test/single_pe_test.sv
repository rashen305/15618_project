/*
* single_pe_test.sv: Tests the top-left corner PE.
*
* Author: Albert Luo (albertlu)
*/

`timescale 1ns/1ns

`include "sa_processing_elem.sv"

module single_pe_test();
    localparam int I_WIDTH = 32;
    localparam int O_WIDTH = 2 * I_WIDTH;

    logic                 clk, rst_l;
    logic                 i_valid;
    logic                 i_acc_clear;
    logic [I_WIDTH - 1:0] i_rowData, i_colData, o_rowData, o_colData;
    logic [O_WIDTH - 1:0] o_accData;

    // Golden MAC output for verification.
    logic [O_WIDTH - 1:0] golden_mac;

    sa_processing_elem #(
        .I_WORD_SIZE(I_WIDTH),
        .O_WORD_SIZE(O_WIDTH)
    )
        processingElem_DUT(.*);

    // Clocking block.
    initial begin
        clk   = 0;
        rst_l = 1;
        golden_mac = '0;

        forever #10 clk = ~clk;
    end

    initial begin
        // Reset PE initially.
        @(posedge clk) begin
            rst_l <= 1'b0;
            i_valid <= 1'b0;
            i_acc_clear <= 1'b1;
        end

        @(posedge clk) begin
            rst_l <= 1'b1;
            i_valid <= 1'b1;
            i_acc_clear <= 1'b0;
        end

        for (int i = 0; i < 5; i++) begin
            i_rowData <= I_WIDTH'(i);
            i_colData <= I_WIDTH'(i + 1);

            // Note that the accumulator data propagates one cycle later.
            golden_mac <= (golden_mac + (i * (i - 1)));

            @(posedge clk);

            RAND_COL_DATA_ASSERT : begin
                assert(o_accData == golden_mac) else begin
                    $error("Expected o_accData = %d, got %d instead.\n",
                           golden_mac, o_accData);
                end
            end

        end

        // Extra cycles before finishing test -- for sanity.
        repeat (5) @(posedge clk);

        $display("\n");
        $display("***************************************************************************");
        $display("                            ALL TESTS PASSED!                              ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : single_pe_test
