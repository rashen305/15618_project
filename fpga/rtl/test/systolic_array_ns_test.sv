/*
 * systolic_array_ns_test.sv: Tests non-stationary (NS / input-stationary)
 * mode of the 2x2 systolic array.
 *
 * NS mode caches the last A[i][k] value in each PE (symmetric to WS which
 * caches B[k][j]).  Once an A value is loaded it is reused for subsequent
 * B columns that stream through with rowValid=0, enabling multi-right-hand-
 * side GEMM without re-feeding A.
 *
 * Phase 1 – standard K=2 wavefront, same matrices as OS/WS tests.
 *   A = [[1,2],[3,4]], B = [[5,6],[7,8]]  →  C = [[19,22],[43,50]]
 *   Verifies NS produces correct GEMM results.
 *
 * Phase 2 – K=1 A-reuse demo.
 *   Load A = [[2],[3]] (K=1 rank-1), B1 = [[4,5]] → C1 = [[8,10],[12,15]]
 *   Then re-use cached A and stream B2 = [[6,7]]   → C2 = [[12,14],[18,21]]
 *   Verifies the A-stationary caching is preserved across acc_clear.
 */

`timescale 1ns/1ns

`include "sa_processing_elem.sv"
`include "systolic_array.sv"

module systolic_array_ns_test();
    localparam int I_WORD_SIZE = 8;
    localparam int O_WORD_SIZE = 2 * I_WORD_SIZE;
    localparam int NUM_ROWS    = 2;
    localparam int NUM_COLS    = 2;

    logic clk;
    logic rst_l;
    logic i_feederDone;
    logic i_acc_clear;
    logic [NUM_ROWS - 1:0]    i_rowsValid;
    logic [NUM_COLS - 1:0]    i_colsValid;
    logic [I_WORD_SIZE - 1:0] i_cellData [NUM_ROWS + NUM_COLS];
    logic [O_WORD_SIZE - 1:0] o_cellData [NUM_ROWS][NUM_COLS];
    logic                     o_compDone;
    logic [O_WORD_SIZE - 1:0] o_accData;

    ns_systolic_array #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .DATAFLOW_MODE(SA_DATAFLOW_NS)
    ) systolicArray_DUT(.*);

    initial begin
        clk   = 0;
        rst_l = 1;
        forever #10 clk = ~clk;
    end

    // Zero all row/col valid & data signals.
    task automatic clearInputs();
        i_rowsValid <= '0;
        i_colsValid <= '0;
        for (int i = 0; i < NUM_ROWS + NUM_COLS; i++)
            i_cellData[i] <= '0;
    endtask : clearInputs

    // Drive one wavefront cycle at the next negedge.
    task automatic driveCycle(
        input logic [NUM_ROWS - 1:0] rowsValid,
        input logic [NUM_COLS - 1:0] colsValid,
        input logic [I_WORD_SIZE - 1:0] col0Data,
        input logic [I_WORD_SIZE - 1:0] col1Data,
        input logic [I_WORD_SIZE - 1:0] row0Data,
        input logic [I_WORD_SIZE - 1:0] row1Data
    );
        @(negedge clk);
        i_rowsValid   <= rowsValid;
        i_colsValid   <= colsValid;
        i_cellData[0] <= col0Data;
        i_cellData[1] <= col1Data;
        i_cellData[2] <= row0Data;
        i_cellData[3] <= row1Data;
    endtask : driveCycle

    // -----------------------------------------------------------------------
    // Phase 1: Standard K=2 wavefront (same stimulus as OS/WS tests).
    //   A = [[1,2],[3,4]]  B = [[5,6],[7,8]]  expected C = [[19,22],[43,50]]
    // -----------------------------------------------------------------------
    initial begin
        rst_l        <= 1'b0;
        i_acc_clear  <= 1'b0;
        i_feederDone <= 1'b0;
        @(posedge clk);
        rst_l <= 1'b1;

        clearInputs();

        driveCycle(2'b01, 2'b01, 8'd5, 8'd0,  8'd1, 8'd0);
        driveCycle(2'b11, 2'b11, 8'd7, 8'd6,  8'd2, 8'd3);
        i_feederDone <= 1'b1;
        driveCycle(2'b10, 2'b10, 8'd0, 8'd8,  8'd0, 8'd4);
        // Drain cycle: clear all valids so stale signals don't trigger
        // extra NS-mode accumulation via stationaryInputValid.
        driveCycle(2'b00, 2'b00, 8'd0, 8'd0,  8'd0, 8'd0);

        @(posedge clk);

        wait (o_compDone) begin
            @(posedge clk);
            NS_PHASE1 : begin
                $display("NS phase-1 (K=2): c00=%0d c01=%0d c10=%0d c11=%0d",
                         o_cellData[0][0], o_cellData[0][1],
                         o_cellData[1][0], o_cellData[1][1]);
                assert(o_cellData[0][0] == 19);
                assert(o_cellData[0][1] == 22);
                assert(o_cellData[1][0] == 43);
                assert(o_cellData[1][1] == 50);
            end
        end

        // -------------------------------------------------------------------
        // Phase 2: K=1 A-reuse demo.
        //
        // Load A = [[2],[3]] with B1 = [[4,5]].
        //   Expected C1[i][j] = A[i] * B1[j]:
        //     c00=2*4=8  c01=2*5=10  c10=3*4=12  c11=3*5=15
        //
        // Then clear accumulators (A stays cached in NS mode) and stream
        // B2 = [[6,7]] with rowsValid=0 (no new A fed).
        //   Expected C2[i][j] = stationaryInput[i][j] * B2[j]:
        //     c00=2*6=12  c01=2*7=14  c10=3*6=18  c11=3*7=21
        // -------------------------------------------------------------------
        @(negedge clk);
        i_acc_clear  <= 1'b1;
        i_feederDone <= 1'b0;
        @(negedge clk);
        i_acc_clear  <= 1'b0;

        // Feed A[[2],[3]] alongside B1[[4,5]] (K=1 rank-1 wavefront).
        // Skewing: A[0] at t=0, A[1] at t=1; B[0] at t=0, B[1] at t=1.
        driveCycle(2'b01, 2'b01, 8'd4, 8'd0,  8'd2, 8'd0);
        driveCycle(2'b10, 2'b10, 8'd0, 8'd5,  8'd0, 8'd3);
        i_feederDone <= 1'b1;
        driveCycle(2'b00, 2'b00, 8'd0, 8'd0,  8'd0, 8'd0);  // drain
        driveCycle(2'b00, 2'b00, 8'd0, 8'd0,  8'd0, 8'd0);

        @(posedge clk);

        wait (o_compDone) begin
            @(posedge clk);
            NS_PHASE2A : begin
                $display("NS phase-2a (A*B1, K=1): c00=%0d c01=%0d c10=%0d c11=%0d",
                         o_cellData[0][0], o_cellData[0][1],
                         o_cellData[1][0], o_cellData[1][1]);
                assert(o_cellData[0][0] == 8);
                assert(o_cellData[0][1] == 10);
                assert(o_cellData[1][0] == 12);
                assert(o_cellData[1][1] == 15);
            end
        end

        // Now clear accumulators – A stays cached (NS mode keeps stationaryInput).
        @(negedge clk);
        i_acc_clear  <= 1'b1;
        i_feederDone <= 1'b0;
        @(negedge clk);
        i_acc_clear  <= 1'b0;

        // Stream B2 = [[6,7]] with rowsValid=0: PEs reuse cached A.
        driveCycle(2'b00, 2'b01, 8'd6, 8'd0,  8'd0, 8'd0);
        driveCycle(2'b00, 2'b10, 8'd0, 8'd7,  8'd0, 8'd0);
        i_feederDone <= 1'b1;
        driveCycle(2'b00, 2'b00, 8'd0, 8'd0,  8'd0, 8'd0);  // drain
        driveCycle(2'b00, 2'b00, 8'd0, 8'd0,  8'd0, 8'd0);

        @(posedge clk);

        wait (o_compDone) begin
            @(posedge clk);
            NS_PHASE2B : begin
                $display("NS phase-2b (A*B2, reuse A): c00=%0d c01=%0d c10=%0d c11=%0d",
                         o_cellData[0][0], o_cellData[0][1],
                         o_cellData[1][0], o_cellData[1][1]);
                assert(o_cellData[0][0] == 12);
                assert(o_cellData[0][1] == 14);
                assert(o_cellData[1][0] == 18);
                assert(o_cellData[1][1] == 21);
            end
        end

        $display("\n");
        $display("***************************************************************************");
        $display("                          NS ARRAY TEST PASSED!                           ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : systolic_array_ns_test
