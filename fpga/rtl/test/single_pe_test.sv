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
    logic [I_WIDTH - 1:0] i_rowData, i_colData;
    logic [O_WIDTH - 1:0] o_rowDataInner, o_colDataInner;
    logic [O_WIDTH - 1:0] o_rowDataEdge, o_colDataEdge;

    // Inner PE (should forward MAC data to the next row).
    sa_processing_elem #(
        .I_WORD_SIZE(I_WIDTH),
        .O_WORD_SIZE(O_WIDTH),
        .IS_FINAL_PE(0)
    )
        innerPE(
            .o_rowData(o_rowDataInner),
            .o_colData(o_colDataInner),
            .*
        );

    // Bottom edge PE (should forward column data to the next row).
    sa_processing_elem #(
        .I_WORD_SIZE(I_WIDTH),
        .O_WORD_SIZE(O_WIDTH),
        .IS_FINAL_PE(1)
    )
        edgePE(
            .o_rowData(o_rowDataEdge),
            .o_colData(o_colDataEdge),
            .*
        );

    initial begin
        clk   = 0;
        rst_l = 1;

        forever #10 clk = ~clk;
    end

    logic [O_WIDTH - 1:0] golden_mac;
    initial begin
        // Reset PE initially.
        rst_l <= 1'b0;
        i_valid <= 1'b0;
        i_acc_clear <= 1'b0;
        @(posedge clk);

        rst_l <= 1'b1;
        i_valid <= 1'b1;
        i_rowData <= I_WIDTH'(4);
        i_colData <= I_WIDTH'(2);
        @(posedge clk);
        i_valid <= 1'b0;
        for (int i = 0; i < 20; i++) begin
            @(posedge clk);

            // Row data should always be the same (unless new input is passed).
            O_ROW_DATA_INNER_ASSERT : assert(o_rowDataInner == 4) else begin
                $display("Expected o_rowDataInner = 4, got %d instead.\n",
                         o_rowDataInner);
            end

            O_ROW_DATA_EDGE_ASSERT : assert(o_rowDataEdge == 4) else begin
                $display("Expected o_rowDataEdge = 4, got %d instead.\n",
                         o_rowDataEdge);
            end

            O_COL_DATA_INNER_ASSERT : assert(o_colDataInner == 8 * (i + 1)) else begin
                $display("Expected o_colDataInner = %d, got %d instead.\n",
                         8 * (i + 1), o_colDataInner);
            end

            O_COL_DATA_EDGE_ASSERT : assert(o_colDataEdge == 2) else begin
                $display("Expected o_colDataEdge = 2, got %d instead.\n",
                         o_colDataEdge);
            end
        end

        i_valid <= 1'b0;
        i_rowData <= I_WIDTH'(167);
        i_colData <= I_WIDTH'(789);
        @(posedge clk);

        NON_VALID_LATCH_ASSERT : begin
            assert(innerPE.rowData != i_rowData) else begin
                $display("Should not have latched data when i_valid = 0.\n");
            end
            assert(innerPE.colData != i_colData) else begin
                $display("Should not have latched data when i_valid = 0.\n");
            end
        end

        i_valid <= 1'b1;
        i_acc_clear <= 1'b1;
        @(posedge clk);
        @(posedge clk);

        CLEAR_ACC_ASSERT : begin
            assert (innerPE.accumulatorData == 0) else begin
                $display("Did not clear accumulator on i_acc_clear.\n");
            end
        end

        i_acc_clear <= 1'b0;
        golden_mac <= '0;
        i_rowData <= '0;
        i_colData <= '0;
        rst_l <= 1'b0;
        @(posedge clk);
        rst_l <= 1'b1;
        @(posedge clk);

        for (int i = 0; i < 3; i++) begin
            i_rowData <= I_WIDTH'(i);
            i_colData <= I_WIDTH'(i + 1);
            @(posedge clk);
            golden_mac <= (golden_mac + (i * (i + 1)));

            RAND_COL_DATA_INNER_ASSERT : begin
                assert (o_colDataInner == golden_mac) else begin
                    $display("Expected o_colDataInner = %d, got %d instead.\n",
                             golden_mac, o_colDataInner);
                end
            end
        end

        // Extra cycles before finishing test -- for sanity.
        repeat (5) @(posedge clk);

        $finish;
    end
endmodule : single_pe_test
