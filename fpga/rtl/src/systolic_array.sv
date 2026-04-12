/*
* systolic_array.sv: Contains the implementation of a parameterizable,
* non-stationary systolic array.
*
* Author: Albert Luo (albertlu)
*/

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
*                  N + M - 1 many inputs at once. Note that this is a linear
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
     input  logic [I_WORD_SIZE - 1:0] i_cellData [NUM_ROWS + NUM_COLS - 1],
     output logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS],
     output logic                     o_compDone);
endmodule : ns_systolic_array
