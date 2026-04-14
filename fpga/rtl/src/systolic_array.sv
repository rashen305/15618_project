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
*   - i_{rows, cols}Valid: A one-hot bit vector to indicate which {rows, cols} have valid data.
*
*   - i_cellData:          An array to store data to be passed into the systolic array
*                          for computation. For an NSSA, at steady-state, can accept
*                          N+M many inputs at once. Note that this is a linear
*                          array, with the top left corner as index 0. The column data
*                          goes first, then the row data (i.e. indices 0...M - 1 for
*                          cols, indices M...N - 1 for rows).
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
     input  logic                     i_feederDone,
     output logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS],
     output logic                     o_compDone);

    localparam int DRAIN = (NUM_ROWS - 1) + (NUM_COLS - 1);
    logic [DRAIN:0] done_shift;

    // Inter-PE wiring signals.
    logic [I_WORD_SIZE - 1:0] rowData[NUM_ROWS][NUM_COLS];
    logic [I_WORD_SIZE - 1:0] colData[NUM_ROWS][NUM_COLS];
    logic [O_WORD_SIZE - 1:0] accData[NUM_ROWS][NUM_COLS];

    // Per-PE valid signal.
    logic                     rowValid[NUM_ROWS][NUM_COLS];
    logic                     colValid[NUM_ROWS][NUM_COLS];

    // Per-PE clear signal.
    logic                     accClear[NUM_ROWS][NUM_COLS];

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            done_shift <= 1'b0;
        end

        else begin
            done_shift <= {done_shift[DRAIN - 1:0], i_feederDone};
        end
    end

    genvar r, c;
    generate
        for (r = 0; r < NUM_ROWS; r++) begin : gen_ROWS
            for (c = 0; c < NUM_COLS; c++) begin : gen_COLS
                logic [I_WORD_SIZE - 1:0] i_peRowData;
                logic [I_WORD_SIZE - 1:0] i_peColData;
                logic                     i_peRowValid;
                logic                     i_peColValid;

                // Left-to-right row data movement.
                if (c == 0) begin : gen_LEFT_EDGE
                    assign i_peRowData  = i_cellData[NUM_COLS + r];
                    assign i_peRowValid = i_rowsValid[r];
                end
                else begin : gen_INNER_ROW
                    assign i_peRowData  = rowData[r][c - 1];
                    assign i_peRowValid = rowValid[r][c - 1];
                end

                // Top-to-bottom column data movement.
                if (r == 0) begin : gen_TOP_EDGE
                    assign i_peColData  = i_cellData[c];
                    assign i_peColValid = i_colsValid[c];
                end
                else begin : gen_INNER_COL
                    assign i_peColData  = colData[r - 1][c];
                    assign i_peColValid = colValid[r - 1][c];
                end

                // TODO: Might have to deal with inter-array scheduling.
                assign accClear[r][c] = 1'b0;

                sa_processing_elem #(
                    .I_WORD_SIZE(I_WORD_SIZE),
                    .O_WORD_SIZE(O_WORD_SIZE)
                ) pe (
                    .clk,
                    .rst_l,
                    .i_rowValid(i_peRowValid),
                    .i_colValid(i_peColValid),
                    .i_acc_clear(accClear[r][c]),
                    .i_rowData(i_peRowData),
                    .i_colData(i_peColData),
                    .o_rowValid(rowValid[r][c]),
                    .o_colValid(colValid[r][c]),
                    .o_rowData(rowData[r][c]),
                    .o_colData(colData[r][c]),
                    .o_accData(accData[r][c])
                );

                assign o_cellData[r][c] = accData[r][c];
            end
        end
    endgenerate

    assign o_compDone = done_shift[DRAIN];
endmodule : ns_systolic_array
`endif // _SYSTOLIC_ARRAY
