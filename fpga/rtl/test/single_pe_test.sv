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
    logic [O_WIDTH - 1:0] o_rowData, o_colData, o_accData;

    sa_processing_elem #(
        .I_WORD_SIZE(I_WIDTH),
        .O_WORD_SIZE(O_WIDTH)
    )
        processingElem_DUT(.*);

    // Clocking block.
    initial begin
        clk   = 0;
        rst_l = 1;

        forever #10 clk = ~clk;
    end

    logic [O_WIDTH - 1:0] golden_mac;
    initial begin
        // Reset PE initially.
        rst_l <= 1'b1;
        i_valid <= 1'b0;
        i_acc_clear <= 1'b0;
        @(posedge clk);
        rst_l <= 1'b0;
        @(posedge clk);

        RESET_ASSERT : begin
            assert(processingElem_DUT.rowData == '0) else begin
                $error("Row data should be cleared on reset.\n");
            end
            assert(processingElem_DUT.colData == '0) else begin
                $error("Column data should be cleared on reset.\n");
            end
        end

        rst_l <= 1'b1;
        i_rowData <= I_WIDTH'(888);
        i_colData <= I_WIDTH'(999);
        @(posedge clk);
        i_valid <= 1'b0;

        NON_VALID_LATCH_ASSERT : begin
            assert(processingElem_DUT.rowData != i_rowData) else begin
                $error("Should not have latched data when i_valid = 0.\n");
            end
            assert(processingElem_DUT.colData != i_colData) else begin
                $error("Should not have latched data when i_valid = 0.\n");
            end
        end

        @(posedge clk);
        i_valid <= 1'b1;

        VALID_MUL_ASSERT : begin
            assert(processingElem_DUT.rowData == i_rowData) else begin
                $error("Should latch data on i_valid. Expected rowData = %d, but got %d.\n",
                         i_rowData, processingElem_DUT.rowData);
            end
            assert(processingElem_DUT.colData == i_colData) else begin
                $error("Should latch data on i_valid. Expected colData = %d, but got %d.\n",
                         i_colData, processingElem_DUT.colData);
            end
            assert(o_accData == (888 * 999)) else begin
                $error("Accumulator should be enabled on i_valid. Expected o_accData = %d, but got %d.\n",
                         888 * 999, o_accData);
            end
        end

        i_acc_clear <= 1'b0;
        @(posedge clk);

        CLEAR_ACC_ASSERT : begin
            assert(o_accData == '0) else begin
                $error("Did not clear accumulator on i_acc_clear.\n");
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

            RAND_COL_DATA_ASSERT : begin
                assert(o_accData == golden_mac) else begin
                    $error("Expected o_colData = %d, got %d instead.\n",
                             golden_mac, o_colData);
                end
            end

            PROP_ROW_COL_ASSERT : begin
                assert(o_rowData == i_rowData) else begin
                    $error("Should propagate input row data to output. Expected %d, but got %d.\n",
                             i_rowData, o_rowData);
                end
                assert(o_colData == i_colData) else begin
                    $error("Should propagate input column data to output. Expected %d, but got %d.\n",
                             i_colData, o_colData);
                end
            end
        end

        // Extra cycles before finishing test -- for sanity.
        repeat (5) @(posedge clk);

        $finish;
    end
endmodule : single_pe_test
