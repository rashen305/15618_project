`timescale 1ns/1ns

`include "sa_double_buffered_feeder.sv"

module double_buffer_feeder_test();
    localparam int I_WORD_SIZE = 8;
    localparam int NUM_ROWS    = 2;
    localparam int K_DIM       = 2;
    localparam int NUM_COLS    = 2;

    logic clk;
    logic rst_l;
    logic i_start;
    logic i_next_valid;
    logic [I_WORD_SIZE - 1:0] i_matrixA0 [NUM_ROWS][K_DIM];
    logic [I_WORD_SIZE - 1:0] i_matrixB0 [K_DIM][NUM_COLS];
    logic [I_WORD_SIZE - 1:0] i_matrixA1 [NUM_ROWS][K_DIM];
    logic [I_WORD_SIZE - 1:0] i_matrixB1 [K_DIM][NUM_COLS];
    logic [NUM_ROWS - 1:0]    o_rowsValid;
    logic [NUM_COLS - 1:0]    o_colsValid;
    logic [I_WORD_SIZE - 1:0] o_cellData [NUM_ROWS + NUM_COLS];
    logic                     o_busy, o_done, o_bankSel;
    int                       done_count;

    sa_double_buffered_feeder #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .K_DIM(K_DIM)
    ) dut(.*);

    initial begin
        clk = 0;
        forever #10 clk = ~clk;
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) done_count <= 0;
        else if (o_done) done_count <= done_count + 1;
    end

    initial begin
        rst_l = 1'b0;
        i_start = 1'b0;
        i_next_valid = 1'b0;

        // bank0 matrices
        i_matrixA0[0][0] <= 8'd1; i_matrixA0[0][1] <= 8'd2;
        i_matrixA0[1][0] <= 8'd3; i_matrixA0[1][1] <= 8'd4;
        i_matrixB0[0][0] <= 8'd5; i_matrixB0[0][1] <= 8'd6;
        i_matrixB0[1][0] <= 8'd7; i_matrixB0[1][1] <= 8'd8;

        // bank1 matrices
        i_matrixA1[0][0] <= 8'd9;  i_matrixA1[0][1] <= 8'd10;
        i_matrixA1[1][0] <= 8'd11; i_matrixA1[1][1] <= 8'd12;
        i_matrixB1[0][0] <= 8'd13; i_matrixB1[0][1] <= 8'd14;
        i_matrixB1[1][0] <= 8'd15; i_matrixB1[1][1] <= 8'd16;

        repeat (2) @(posedge clk);
        rst_l <= 1'b1;

        // Kick first wave.
        i_start <= 1'b1;
        @(posedge clk);
        i_start <= 1'b0;

        // Arm second bank while first is active.
        repeat (2) @(posedge clk);
        i_next_valid <= 1'b1;
        @(posedge clk);
        i_next_valid <= 1'b0;

        wait (done_count == 2);
        assert(o_bankSel == 1'b1);
        $display("DOUBLE BUFFER FEEDER TEST PASSED");
        $finish;
    end
endmodule

