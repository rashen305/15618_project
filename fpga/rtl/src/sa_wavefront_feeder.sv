`ifndef _SA_WAVEFRONT_FEEDER
`define _SA_WAVEFRONT_FEEDER

`include "sa_params.sv"

module sa_wavefront_feeder
    #(parameter int I_WORD_SIZE = MATRIX_WORD_SIZE,
      parameter int NUM_ROWS    = SA_ROWS,
      parameter int NUM_COLS    = SA_COLS,
      parameter int K_DIM       = NUM_COLS)
    (input  logic clk,
     input  logic rst_l,
     input  logic i_start,
     input  logic [I_WORD_SIZE - 1:0] i_matrixA [NUM_ROWS][K_DIM],
     input  logic [I_WORD_SIZE - 1:0] i_matrixB [K_DIM][NUM_COLS],
     output logic [NUM_ROWS - 1:0]    o_rowsValid,
     output logic [NUM_COLS - 1:0]    o_colsValid,
     output logic [I_WORD_SIZE - 1:0] o_cellData [NUM_ROWS + NUM_COLS],
     output logic                     o_busy,
     output logic                     o_done);

    localparam int TOTAL_CYCLES = K_DIM + NUM_ROWS + NUM_COLS - 2;
    localparam int COUNT_W      = (TOTAL_CYCLES <= 1) ? 1 : $clog2(TOTAL_CYCLES + 1);

    logic [COUNT_W - 1:0] cycle_count;
    logic                 active;
    integer               i, j;
    integer               k_row, k_col;

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            cycle_count <= '0;
            active      <= 1'b0;
            o_done      <= 1'b0;
        end

        else begin
            o_done <= 1'b0;

            if (i_start & ~active) begin
                cycle_count <= '0;
                active      <= 1'b1;
            end

            else if (active) begin
                if (cycle_count == TOTAL_CYCLES - 1) begin
                    cycle_count <= '0;
                    active      <= 1'b0;
                    o_done      <= 1'b1;
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

        for (int x = 0; x < NUM_ROWS + NUM_COLS; x++) begin
            o_cellData[x] = '0;
        end

        if (active) begin
            // Row injections -- inject A[i][k] at time t = i + k.
            for (i = 0; i < NUM_ROWS; i++) begin
                k_row = cycle_count - i;

                if ((k_row >= '0) && (k_row < K_DIM)) begin
                    o_rowsValid[i] = 1'b1;
                    o_cellData[NUM_COLS + i] = i_matrixA[i][k_row];
                end
            end

            // Column injections -- inject B[k][j] at time t = j + k.
            for (j = 0; j < NUM_COLS; j++) begin
                k_col = cycle_count - j;

                if ((k_col >= '0) && (k_col < K_DIM)) begin
                    o_colsValid[j] = 1'b1;
                    o_cellData[j] = i_matrixB[k_col][j];
                end
            end
        end
    end
endmodule : sa_wavefront_feeder
`endif
