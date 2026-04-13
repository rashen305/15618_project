/*
* systolic_array.sv: Contains the implementation of a parameterizable,
* non-stationary systolic array.
*
* Author: Albert Luo (albertlu)
*/

`ifndef _SYSTOLIC_ARRAY
`define _SYSTOLIC_ARRAY

`include "sa_processing_elem.sv"
`include "lib.sv"

/*
* A non-stationary systolic array.
*
* Parameters:
*   - I_WORD_SIZE: Input word size. For acceptors, this is the matrix word size,
*                  but for inner PEs, it will be double that.
*
*   - O_WORD_SIZE: By default, is double I_WORD_SIZE. Should only modify if
*                  output range is unecessarily large.
*
*   - NUM_ROWS:    Number of rows in the systolic array.
*
*   - NUM_COLS:    Number of columns in the systolic array.
*
*  Inputs:
*   - i_rowsValid: A one-hot bit vector to indicate which rows have valid data
*                  (to be latched).
*
*   - i_colsValid: A one-hot bit vector to indicate which cols have valid data
*                  (to be latched).
*
*   - i_cellData:  An array to store data to be passed into the systolic array
*                  for computation. For an NSSA, at steady-state, can accept
*                  N+M many inputs at once. Note that this is a linear
*                  array, with the top left corner as index 0. The column data
*                  goes first, then the row data (i.e. indices 0...M - 1 for
*                  cols, indices M...N - 1 for rows).
*
*  Outputs:
*   - o_cellData:  The data stored in each PE of the systolic array.
*
*   - o_compDone:  When asserted, indicates that the results are all ready. Each
*                  processing element stores one cell of the product array.
*/
module ns_systolic_array
    #(parameter int I_WORD_SIZE = MATRIX_WORD_SIZE,
      parameter int O_WORD_SIZE = 2 * I_WORD_SIZE,
      parameter int NUM_ROWS    = SA_ROWS,
      parameter int NUM_COLS    = SA_COLS)
    (input  logic clk,
     input  logic rst_l,
     input  logic [NUM_ROWS - 1:0]    i_rowsValid,
     input  logic [NUM_COLS - 1:0]    i_colsValid,
     input  logic [I_WORD_SIZE - 1:0] i_cellData [NUM_ROWS + NUM_COLS],
     output logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS],
     output logic                     o_compDone);

    // Inter-PE wiring signals.
    logic [I_WORD_SIZE - 1:0] rowData[NUM_ROWS][NUM_COLS];
    logic [I_WORD_SIZE - 1:0] colData[NUM_ROWS][NUM_COLS];
    logic [O_WORD_SIZE - 1:0] accData[NUM_ROWS][NUM_COLS];

    // Per-PE valid signal.
    logic                     peValid[NUM_ROWS][NUM_COLS];

    // Per-PE clear signal.
    logic                     accClear[NUM_ROWS][NUM_COLS];

    genvar r, c;
    generate
        for (r = 0; r < NUM_ROWS; r++) begin : gen_ROWS
            for (c = 0; c < NUM_COLS; c++) begin : gen_COLS
                logic [I_WORD_SIZE - 1:0] i_pe_row;
                logic [I_WORD_SIZE - 1:0] i_pe_col;
                logic                     i_pe_valid;

                // Left-to-right row data movement.
                if (c == 0) begin : gen_LEFT_EDGE
                    assign i_pe_row = i_cellData[NUM_COLS + r];
                end
                else begin : gen_INNER_ROW
                    assign i_pe_row = rowData[r][c - 1];
                end

                // Top-to-bottom column data movement.
                if (r == 0) begin : gen_TOP_EDGE
                    assign i_pe_col = i_cellData[c];
                end
                else begin : gen_INNER_COL
                    assign i_pe_col = colData[r - 1][c];
                end

                // Valid signal propagation.
                if ((r == 0) && (c == 0)) begin : gen_VALID_TOP_LEFT
                    assign i_pe_valid = (i_rowsValid[0] & i_colsValid[0]);
                end
                else if (c == 0) begin : gen_VALID_LEFT
                    assign i_pe_valid = i_rowsValid[r];
                end
                else if (r == 0) begin : gen_VALID_TOP
                    assign i_pe_valid = i_colsValid[c];
                end
                else begin : gen_VALID_INNER
                    assign i_pe_valid = peValid[r - 1][c - 1];
                end

                // TODO: Might have to deal with inter-array scheduling.
                assign accClear[r][c] = 1'b0;

                sa_processing_elem #(
                    .I_WORD_SIZE(I_WORD_SIZE),
                    .O_WORD_SIZE(O_WORD_SIZE)
                ) pe (
                    .clk,
                    .rst_l,
                    .i_valid(i_pe_valid),
                    .i_acc_clear(accClear[r][c]),
                    .i_rowData(i_pe_row),
                    .i_colData(i_pe_col),
                    .o_rowData(rowData[r][c]),
                    .o_colData(colData[r][c]),
                    .o_accData(accData[r][c])
                );

                assign peValid[r][c]    = i_pe_valid;
                assign o_cellData[r][c] = accData[r][c];
            end
        end
    endgenerate
endmodule : ns_systolic_array
`endif // _SYSTOLIC_ARRAY
