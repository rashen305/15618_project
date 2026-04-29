/*
* systolic_gemm_engine_test.sv: Verifies that the multi-shape engine can run
* several differently dimensioned systolic-array slots against the same memory
* model and produce identical GEMM results.
*/

`timescale 1ns/1ns

`include "main_memory_model.sv"
`include "systolic_gemm_engine.sv"

module systolic_gemm_engine_test();
    localparam int I_WORD_SIZE    = 8;
    localparam int O_WORD_SIZE    = 32;
    localparam int DIM_WIDTH      = 16;
    localparam int ADDR_WIDTH     = 18;
    localparam int MEM_DATA_WIDTH = 32;
    localparam int MEM_BYTES      = MEM_DATA_WIDTH / 8;
    localparam int DEPTH_WORDS    = 4096;

    localparam int M_DIM          = 5;
    localparam int N_DIM          = 6;
    localparam int K_DIM          = 7;
    localparam int A_BASE_WORD    = 0;
    localparam int B_BASE_WORD    = 512;
    localparam int C0_BASE_WORD   = 1024;
    localparam int C1_BASE_WORD   = 1280;
    localparam int C2_BASE_WORD   = 1536;

    logic clk;
    logic rst_l;
    logic start;
    logic [1:0] array_select;
    logic [ADDR_WIDTH - 1:0] base_c;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [ADDR_WIDTH - 1:0] mem_req_addr;
    logic [MEM_DATA_WIDTH - 1:0] mem_req_wdata;
    logic [MEM_BYTES - 1:0] mem_req_wstrb;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic mem_rsp_write;
    logic [ADDR_WIDTH - 1:0] mem_rsp_addr;
    logic [MEM_DATA_WIDTH - 1:0] mem_rsp_rdata;

    logic busy;
    logic done;
    logic error;
    logic [1:0] active_array;
    logic [63:0] cycles;
    logic [63:0] compute_cycles;
    logic [63:0] memory_stall_cycles;
    logic [63:0] prefetch_cycles;
    logic [63:0] compute_wait_cycles;
    logic [63:0] read_reqs;
    logic [63:0] write_reqs;
    logic [63:0] loaded_tile_count;
    logic [63:0] tile_count;

    logic [63:0] mem_cycles;
    logic [63:0] mem_reads;
    logic [63:0] mem_writes;
    logic [63:0] mem_bytes_read;
    logic [63:0] mem_bytes_written;
    logic [63:0] mem_stalls;

    logic [I_WORD_SIZE - 1:0] a_matrix [0:M_DIM - 1][0:K_DIM - 1];
    logic [I_WORD_SIZE - 1:0] b_matrix [0:K_DIM - 1][0:N_DIM - 1];
    logic [O_WORD_SIZE - 1:0] expected_c [0:M_DIM - 1][0:N_DIM - 1];

    main_memory_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(MEM_DATA_WIDTH),
        .DEPTH_WORDS(DEPTH_WORDS),
        .MAX_OUTSTANDING(16),
        .READ_LATENCY(8),
        .WRITE_LATENCY(4),
        .BANKS(4),
        .ROW_WORDS(64),
        .ROW_HIT_LATENCY(3),
        .ROW_MISS_PENALTY(10),
        .MODEL_ROW_BUFFER(1'b1)
    ) mem (
        .clk,
        .rst_l,
        .i_req_valid(mem_req_valid),
        .o_req_ready(mem_req_ready),
        .i_req_write(mem_req_write),
        .i_req_addr(mem_req_addr),
        .i_req_wdata(mem_req_wdata),
        .i_req_wstrb(mem_req_wstrb),
        .o_rsp_valid(mem_rsp_valid),
        .i_rsp_ready(mem_rsp_ready),
        .o_rsp_write(mem_rsp_write),
        .o_rsp_addr(mem_rsp_addr),
        .o_rsp_rdata(mem_rsp_rdata),
        .o_cycle_count(mem_cycles),
        .o_read_count(mem_reads),
        .o_write_count(mem_writes),
        .o_bytes_read(mem_bytes_read),
        .o_bytes_written(mem_bytes_written),
        .o_stall_req_count(mem_stalls)
    );

    systolic_gemm_engine #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .ENABLE_DOUBLE_BUFFER(1'b1),
        .SLOT0_ROWS(2),
        .SLOT0_COLS(2),
        .SLOT0_K_TILE(3),
        .SLOT1_ROWS(3),
        .SLOT1_COLS(4),
        .SLOT1_K_TILE(4),
        .SLOT2_ROWS(4),
        .SLOT2_COLS(3),
        .SLOT2_K_TILE(5)
    ) engine (
        .clk,
        .rst_l,
        .i_start(start),
        .i_array_select(array_select),
        .i_m(DIM_WIDTH'(M_DIM)),
        .i_n(DIM_WIDTH'(N_DIM)),
        .i_k(DIM_WIDTH'(K_DIM)),
        .i_base_a(ADDR_WIDTH'(A_BASE_WORD * MEM_BYTES)),
        .i_base_b(ADDR_WIDTH'(B_BASE_WORD * MEM_BYTES)),
        .i_base_c(base_c),
        .i_stride_a(DIM_WIDTH'(K_DIM)),
        .i_stride_b(DIM_WIDTH'(N_DIM)),
        .i_stride_c(DIM_WIDTH'(N_DIM)),
        .o_mem_req_valid(mem_req_valid),
        .i_mem_req_ready(mem_req_ready),
        .o_mem_req_write(mem_req_write),
        .o_mem_req_addr(mem_req_addr),
        .o_mem_req_wdata(mem_req_wdata),
        .o_mem_req_wstrb(mem_req_wstrb),
        .i_mem_rsp_valid(mem_rsp_valid),
        .o_mem_rsp_ready(mem_rsp_ready),
        .i_mem_rsp_write(mem_rsp_write),
        .i_mem_rsp_addr(mem_rsp_addr),
        .i_mem_rsp_rdata(mem_rsp_rdata),
        .o_busy(busy),
        .o_done(done),
        .o_error(error),
        .o_active_array(active_array),
        .o_cycles(cycles),
        .o_compute_cycles(compute_cycles),
        .o_memory_stall_cycles(memory_stall_cycles),
        .o_prefetch_cycles(prefetch_cycles),
        .o_compute_wait_cycles(compute_wait_cycles),
        .o_read_reqs(read_reqs),
        .o_write_reqs(write_reqs),
        .o_loaded_tile_count(loaded_tile_count),
        .o_tile_count(tile_count)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic initialize_problem();
        logic [O_WORD_SIZE - 1:0] sum;

        mem.clear_memory();

        for (int r = 0; r < M_DIM; r++) begin
            for (int kk = 0; kk < K_DIM; kk++) begin
                a_matrix[r][kk] = I_WORD_SIZE'(((r + 2) * (kk + 1)) % 23);
                mem.write_word(A_BASE_WORD + (r * K_DIM) + kk,
                               MEM_DATA_WIDTH'(a_matrix[r][kk]));
            end
        end

        for (int kk = 0; kk < K_DIM; kk++) begin
            for (int c = 0; c < N_DIM; c++) begin
                b_matrix[kk][c] = I_WORD_SIZE'(((kk + 4) * (c + 3)) % 29);
                mem.write_word(B_BASE_WORD + (kk * N_DIM) + c,
                               MEM_DATA_WIDTH'(b_matrix[kk][c]));
            end
        end

        for (int r = 0; r < M_DIM; r++) begin
            for (int c = 0; c < N_DIM; c++) begin
                sum = '0;
                for (int kk = 0; kk < K_DIM; kk++) begin
                    sum += O_WORD_SIZE'(a_matrix[r][kk]) * O_WORD_SIZE'(b_matrix[kk][c]);
                end
                expected_c[r][c] = sum;
            end
        end
    endtask : initialize_problem

    task automatic run_slot(input logic [1:0] slot,
                            input int unsigned slot_rows,
                            input int unsigned slot_cols,
                            input int unsigned slot_ktile,
                            input int unsigned c_base_word);
        logic [MEM_DATA_WIDTH - 1:0] got;
        longint unsigned macs;
        longint unsigned ops;
        real ops_per_cycle;
        real pe_util;

        array_select <= slot;
        base_c       <= ADDR_WIDTH'(c_base_word * MEM_BYTES);
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        fork
            begin
                repeat (300000) @(posedge clk);
                $fatal(1, "Timed out waiting for engine slot %0d.", slot);
            end

            begin
                wait (done);
            end
        join_any
        disable fork;

        assert(!error) else $fatal(1, "Engine slot %0d reported an error.", slot);

        for (int r = 0; r < M_DIM; r++) begin
            for (int c = 0; c < N_DIM; c++) begin
                got = mem.read_word(c_base_word + (r * N_DIM) + c);
                assert(got[O_WORD_SIZE - 1:0] == expected_c[r][c])
                    else $fatal(1, "slot %0d C[%0d][%0d] expected %0d, got %0d.",
                                slot, r, c, expected_c[r][c], got[O_WORD_SIZE - 1:0]);
            end
        end

        macs = longint'(M_DIM) * longint'(N_DIM) * longint'(K_DIM);
        ops = 2 * macs;
        ops_per_cycle = (cycles == 0) ? 0.0 : real'(ops) / real'(cycles);
        pe_util = (compute_cycles == 0) ? 0.0 :
                  real'(macs) / (real'(slot_rows * slot_cols) * real'(compute_cycles));

        $display("engine_bench,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%.6f",
                 slot, slot_rows, slot_cols, slot_ktile, M_DIM, N_DIM, K_DIM,
                 cycles, compute_cycles, prefetch_cycles, compute_wait_cycles,
                 read_reqs, write_reqs, ops_per_cycle, pe_util);
    endtask : run_slot

    initial begin
        rst_l        <= 1'b0;
        start        <= 1'b0;
        array_select <= 2'd0;
        base_c       <= ADDR_WIDTH'(C0_BASE_WORD * MEM_BYTES);

        repeat (4) @(posedge clk);
        rst_l <= 1'b1;
        initialize_problem();

        $display("engine_bench_header,slot,rows,cols,k_tile,m,n,k,cycles,compute_cycles,prefetch_cycles,compute_wait_cycles,reads,writes,ops_per_cycle,pe_util");
        run_slot(2'd0, 2, 2, 3, C0_BASE_WORD);
        run_slot(2'd1, 3, 4, 4, C1_BASE_WORD);
        run_slot(2'd2, 4, 3, 5, C2_BASE_WORD);

        $display("\n");
        $display("***************************************************************************");
        $display("                     SYSTOLIC GEMM ENGINE TESTS PASSED                     ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : systolic_gemm_engine_test
