/*
* sa_processing_elem.sv: Contains the implementation of a single processing
* element for the systolic array. Currently, we only implement the stationary
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
*   - I_WORD_SIZE: Input word size. For acceptors, this is the matrix word
*                  size, but for inner PEs, it will be double that.
*
* Inputs:
*   - clk:         System clock -- we will try to run this as fast as possible.
*   - rst_l:       Active low synchoronous reset.
*   - i_valid:     Indicates that the data is valid/ready for computation. Should
*                  be asserted only for one cycle.
*   - i_rowData:   Data from the PE in the previous column. For acceptors, this is
*                  the matrix row data.
*   - i_colData:   Data from the PE in the previous row. For acceptors, this is
*                  the matrix column data.
*
* Outputs:
*   - o_rowData:   Depending on the architecture, is the data passed to the PE
*                  in the next column.
*   - o_colData:   Depending on the architecture, is the data passed to the PE
*                  in the next row.
*/
module sa_processing_elem
    #(parameter int I_WORD_SIZE = MATRIX_WORD_SIZE,
      parameter int O_WORD_SIZE = (I_WORD_SIZE * 2),
      parameter int IS_FINAL_PE = 0)
    (input  logic                     clk,
     // TODO: Synchronous reset for now -- should probably change later.
     input  logic                     rst_l,
     input  logic                     i_valid,
     input  logic                     i_acc_clear,
     input  logic [I_WORD_SIZE - 1:0] i_rowData,
     input  logic [I_WORD_SIZE - 1:0] i_colData,
     output logic [O_WORD_SIZE - 1:0] o_rowData,
     output logic [O_WORD_SIZE - 1:0] o_colData);

    logic [I_WORD_SIZE - 1:0] rowData, colData;
    logic [O_WORD_SIZE - 1:0] multOut;
    logic [O_WORD_SIZE - 1:0] macOut;
    logic [O_WORD_SIZE - 1:0] accumulatorData;

    // Latch input data.
    register #(.WIDTH(I_WORD_SIZE))
        rowReg(.clk,
               .rst_l,
               .clear(i_acc_clear),
               .en(i_valid),
               .regIn(i_rowData),
               .regOut(rowData)),
        colReg(.clk,
               .rst_l,
               .clear(i_acc_clear),
               .en(i_valid),
               .regIn(i_colData),
               .regOut(colData));

    // Store accumulator data for C[i][j].
    register #(.WIDTH(O_WORD_SIZE))
        accumulatorReg(.clk,
               .rst_l,
               .clear(i_acc_clear),
               .en(1'b1),
               .regIn(macOut),
               .regOut(accumulatorData));

    // Multiply inputs.
    multiplier #(.I_WIDTH(I_WORD_SIZE))
        macMultiplier(.multIn1(rowData),
                      .multIn2(colData),
                      .multOut);

    // Accumulate with current C[i][j] value.
    adder #(.WIDTH(O_WORD_SIZE))
        macAdder(.adderIn1(accumulatorData),
                 .adderIn2(multOut),
                 .adderOut(macOut));

    assign o_rowData = rowData;

    always_comb begin
        if (IS_FINAL_PE) begin
            o_colData = (i_acc_clear) ? '0 : i_colData;
        end

        else begin
            o_colData = (i_acc_clear) ? '0 : macOut;
        end
    end
endmodule : sa_processing_elem
`endif // _SA_PROCESSING_ELEM
