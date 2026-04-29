/*
* sa_processing_elem.sv: Contains the implementation of a single processing
* element for the systolic array. Currently, we only implement the non-stationary
* type.
*
* Author: Albert Luo (albertlu)
*/

`ifndef _SA_PROCESSING_ELEM
`define _SA_PROCESSING_ELEM

`include "sa_params.sv"
`include "lib.sv"

/*
* A single systolic array PE.
*
* Parameters:
*   - I_WORD_SIZE: Input word size. Since this is for a NSSA, only the inputs
*                  propagate.
*
* Inputs:
*   - clk:                System clock -- we will try to run this as fast as possible.
*
*   - rst_l:              Active low synchoronous reset.
*
*   - i_{row, col}Valid:  Indicates that the {row, column} data is valid/ready for computation.
*
*   - i_{row, col}Data:   Data from the PE in the previous {column, row}. For acceptors, this is
*                         the matrix row data.
*
* Outputs:
*   - o_rowData:   Input row data to be passed to the PE in the next column.
*
*   - o_colData:   Input column data to be passed to the PE in the next row.
*
*   - o_accData:   Partial sum that the PE currently holds.
*/
module sa_processing_elem
    #(parameter int I_WORD_SIZE = MATRIX_WORD_SIZE,
      parameter int O_WORD_SIZE = I_WORD_SIZE,
      parameter int DATAFLOW_MODE = SA_DATAFLOW_OS)
    (input  logic                     clk,
     // TODO: Synchronous reset for now -- should probably change later.
     input  logic                     rst_l,
     input  logic                     i_rowValid,
     input  logic                     i_colValid,
     input  logic                     i_acc_clear,
     input  logic [I_WORD_SIZE - 1:0] i_rowData,
     input  logic [I_WORD_SIZE - 1:0] i_colData,
     output logic                     o_rowValid,
     output logic                     o_colValid,
     output logic [I_WORD_SIZE - 1:0] o_rowData,
     output logic [I_WORD_SIZE - 1:0] o_colData,
     output logic [O_WORD_SIZE - 1:0] o_accData);

    logic [I_WORD_SIZE - 1:0] rowData, colData;
    logic [I_WORD_SIZE - 1:0] stationaryWeight;
    logic                     stationaryWeightValid;
    logic [I_WORD_SIZE - 1:0] multColData;
    logic [O_WORD_SIZE - 1:0] multOut;
    logic [O_WORD_SIZE - 1:0] macOut;
    logic [O_WORD_SIZE - 1:0] accumulatorData;
    logic                     compValid;

    // Both modes require both operands to be present to compute.
    // For WS multi-tile reuse (row-only streaming after B preload) the caller
    // is expected to keep i_colValid asserted or drive the weight separately;
    // single-tile GEMM is identical to OS with the fixes below.
    assign compValid = (i_rowValid & i_colValid);

    // WS: on the cycle i_colData first arrives it has not yet been clocked into
    //     stationaryWeight, so use the live i_colData directly.  Once the weight
    //     register is valid and no new col data is present, fall back to it.
    //     OS: always use the live i_colData.
    assign multColData = (DATAFLOW_MODE == SA_DATAFLOW_WS)
                         ? (i_colValid ? i_colData : stationaryWeight)
                         : i_colData;

    // Latch input data.
    register #(.WIDTH(I_WORD_SIZE))
        rowReg(.clk,
               .rst_l,
               .clear(1'b0),
               .en(compValid),
               .regIn(i_rowData),
               .regOut(rowData)),
        colReg(.clk,
               .rst_l,
               .clear(1'b0),
               .en(compValid),
               .regIn(i_colData),
               .regOut(colData));

    register #(.WIDTH(1))
        rowValidReg(.clk,
                 .rst_l,
                 .clear(i_acc_clear),
                 .en(1'b1),
                 .regIn(i_rowValid),
                 .regOut(o_rowValid)),
        colValidReg(.clk,
                 .rst_l,
                 .clear(i_acc_clear),
                 .en(1'b1),
                 .regIn(i_colValid),
                 .regOut(o_colValid));

    // Store accumulator data for C[i][j].
    register #(.WIDTH(O_WORD_SIZE))
        accumulatorReg(.clk,
               .rst_l,
               .clear(i_acc_clear),
               .en(compValid),
               .regIn(macOut),
               .regOut(accumulatorData));

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            stationaryWeight      <= '0;
            stationaryWeightValid <= 1'b0;
        end

        else if (i_acc_clear) begin
            stationaryWeight      <= '0;
            stationaryWeightValid <= 1'b0;
        end

        else if ((DATAFLOW_MODE == SA_DATAFLOW_WS) && i_colValid) begin
            // Update on every arriving column value so that the last-seen
            // B[k][j] is retained for weight reuse across subsequent A tiles.
            stationaryWeight      <= i_colData;
            stationaryWeightValid <= 1'b1;
        end
    end

    // TODO: Pipeline the MAC operation.

    // Multiply inputs.
    multiplier #(.I_WIDTH(I_WORD_SIZE),
                 .O_WIDTH(O_WORD_SIZE))
        macMultiplier(.multIn1(i_rowData),
                      .multIn2(multColData),
                      .multOut);

    // Accumulate with current C[i][j] value.
    adder #(.WIDTH(O_WORD_SIZE))
        macAdder(.adderIn1(accumulatorData),
                 .adderIn2(multOut),
                 .adderOut(macOut));

    assign o_rowData = rowData;
    assign o_colData = colData;
    assign o_accData = accumulatorData;
endmodule : sa_processing_elem
`endif // _SA_PROCESSING_ELEM
