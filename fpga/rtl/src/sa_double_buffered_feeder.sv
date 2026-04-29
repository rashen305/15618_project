`ifndef _SA_DOUBLE_BUFFERED_FEEDER
`define _SA_DOUBLE_BUFFERED_FEEDER

`include "sa_params.sv"

module sa_double_buffered_feeder
    #(parameter int I_WORD_SIZE = MATRIX_WORD_SIZE,
      parameter int NUM_ROWS    = SA_ROWS,
      parameter int NUM_COLS    = SA_COLS,
      parameter int K_DIM       = NUM_COLS)
    (input  logic clk,
     input  logic rst_l,
     input  logic i_start,
     input  logic i_next_valid,
     input  logic [I_WORD_SIZE - 1:0] i_matrixA0 [NUM_ROWS][K_DIM],
     input  logic [I_WORD_SIZE - 1:0] i_matrixB0 [K_DIM][NUM_COLS],
     input  logic [I_WORD_SIZE - 1:0] i_matrixA1 [NUM_ROWS][K_DIM],
     input  logic [I_WORD_SIZE - 1:0] i_matrixB1 [K_DIM][NUM_COLS],
     output logic [NUM_ROWS - 1:0]    o_rowsValid,
     output logic [NUM_COLS - 1:0]    o_colsValid,
     output logic [I_WORD_SIZE - 1:0] o_cellData [NUM_ROWS + NUM_COLS],
     output logic                     o_busy,
     output logic                     o_done,
     output logic                     o_bankSel);

    localparam int TOTAL_CYCLES = K_DIM + NUM_ROWS + NUM_COLS - 2;
    localparam int COUNT_W      = (TOTAL_CYCLES <= 1) ? 1 : $clog2(TOTAL_CYCLES + 1);

    logic [COUNT_W - 1:0] cycle_count;
    logic                 active;
    logic                 bankSel;
    logic                 next_pending;
    integer               i, j;
    integer               k_row, k_col;

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            cycle_count   <= '0;
            active        <= 1'b0;
            bankSel       <= 1'b0;
            next_pending  <= 1'b0;
            o_done        <= 1'b0;
        end

        else begin
            o_done <= 1'b0;

            if (i_next_valid) begin
                next_pending <= 1'b1;
            end

            if (i_start & ~active) begin
                cycle_count <= '0;
                active      <= 1'b1;
            end

            else if (active) begin
                if (cycle_count == TOTAL_CYCLES - 1) begin
                    o_done      <= 1'b1;
                    cycle_count <= '0;
                    if (next_pending) begin
                        // Immediately roll to next bank with no feeder bubble.
                        bankSel      <= ~bankSel;
                        next_pending <= 1'b0;
                        active       <= 1'b1;
                    end
                    else begin
                        active <= 1'b0;
                    end
                end
                else begin
                    cycle_count <= cycle_count + 1;
                end
            end
        end
    end

    always_comb begin
        o_rowsValid = '0;
        o_colsValid = '0;
        o_busy      = active;
        o_bankSel   = bankSel;

        for (int x = 0; x < NUM_ROWS + NUM_COLS; x++) begin
            o_cellData[x] = '0;
        end

        if (active) begin
            for (i = 0; i < NUM_ROWS; i++) begin
                k_row = cycle_count - i;
                if ((k_row >= 0) && (k_row < K_DIM)) begin
                    o_rowsValid[i] = 1'b1;
                    o_cellData[NUM_COLS + i] = bankSel ? i_matrixA1[i][k_row]
                                                       : i_matrixA0[i][k_row];
                end
            end

            for (j = 0; j < NUM_COLS; j++) begin
                k_col = cycle_count - j;
                if ((k_col >= 0) && (k_col < K_DIM)) begin
                    o_colsValid[j] = 1'b1;
                    o_cellData[j] = bankSel ? i_matrixB1[k_col][j]
                                            : i_matrixB0[k_col][j];
                end
            end
        end
    end
endmodule : sa_double_buffered_feeder
`endif

