/*
* sa_benchmark_test.sv: Parameterized FPGA-side benchmark harness. It runs the
* memory-backed tiled GEMM controller, verifies the result, and prints a CSV row
* with cycle, memory, and utilization metrics suitable for roofline analysis.
*/

`timescale 1ns/1ns

`include "main_memory_model.sv"
`include "tiled_gemm_accelerator.sv"

module sa_benchmark_test #(
    parameter int I_WORD_SIZE       = 8,
    parameter int O_WORD_SIZE       = 32,
    parameter int NUM_ROWS          = 4,
    parameter int NUM_COLS          = 4,
    parameter int K_TILE            = 8,
    parameter int M_DIM             = 8,
    parameter int N_DIM             = 8,
    parameter int K_DIM             = 8,
    parameter int VALUE_MAX         = 9,
    parameter int ADDR_WIDTH        = 24,
    parameter int MEM_DATA_WIDTH    = 32,
    parameter int DEPTH_WORDS       = 1 << 16,
    parameter int READ_LATENCY      = 40,
    parameter int WRITE_LATENCY     = 20,
    parameter int READ_ACCEPT_GAP   = 0,
    parameter int WRITE_ACCEPT_GAP  = 0,
    parameter int BANKS             = 4,
    parameter int ROW_WORDS         = 1024,
    parameter int ROW_HIT_LATENCY   = 12,
    parameter int ROW_MISS_PENALTY  = 28,
    parameter int CLOCK_MHZ         = 100
)();
    localparam int DIM_WIDTH   = 32;
    localparam int MEM_BYTES   = MEM_DATA_WIDTH / 8;
    localparam int A_BASE_WORD = 0;
    localparam int B_BASE_WORD = A_BASE_WORD + (M_DIM * K_DIM) + 128;
    localparam int C_BASE_WORD = B_BASE_WORD + (K_DIM * N_DIM) + 128;

    logic clk;
    logic rst_l;
    logic start;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [ADDR_WIDTH - 1:0] mem_req_addr;
    logic [MEM_DATA_WIDTH - 1:0] mem_req_wdata;
    logic [(MEM_DATA_WIDTH / 8) - 1:0] mem_req_wstrb;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic mem_rsp_write;
    logic [ADDR_WIDTH - 1:0] mem_rsp_addr;
    logic [MEM_DATA_WIDTH - 1:0] mem_rsp_rdata;

    logic busy;
    logic done;
    logic error;
    logic [63:0] cycles;
    logic [63:0] compute_cycles;
    logic [63:0] memory_stall_cycles;
    logic [63:0] accel_reads;
    logic [63:0] accel_writes;
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
        .READ_LATENCY(READ_LATENCY),
        .WRITE_LATENCY(WRITE_LATENCY),
        .READ_ACCEPT_GAP(READ_ACCEPT_GAP),
        .WRITE_ACCEPT_GAP(WRITE_ACCEPT_GAP),
        .BANKS(BANKS),
        .ROW_WORDS(ROW_WORDS),
        .ROW_HIT_LATENCY(ROW_HIT_LATENCY),
        .ROW_MISS_PENALTY(ROW_MISS_PENALTY),
        .MODEL_ROW_BUFFER(1'b1)
    ) memModel (
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

    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .K_TILE(K_TILE),
        .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH)
    ) dut (
        .clk,
        .rst_l,
        .i_start(start),
        .i_m(DIM_WIDTH'(M_DIM)),
        .i_n(DIM_WIDTH'(N_DIM)),
        .i_k(DIM_WIDTH'(K_DIM)),
        .i_base_a(ADDR_WIDTH'(A_BASE_WORD * MEM_BYTES)),
        .i_base_b(ADDR_WIDTH'(B_BASE_WORD * MEM_BYTES)),
        .i_base_c(ADDR_WIDTH'(C_BASE_WORD * MEM_BYTES)),
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
        .o_cycles(cycles),
        .o_compute_cycles(compute_cycles),
        .o_memory_stall_cycles(memory_stall_cycles),
        .o_read_reqs(accel_reads),
        .o_write_reqs(accel_writes),
        .o_tile_count(tile_count)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic initialize_problem();
        logic [O_WORD_SIZE - 1:0] sum;

        memModel.clear_memory();

        for (int r = 0; r < M_DIM; r++) begin
            for (int kk = 0; kk < K_DIM; kk++) begin
                a_matrix[r][kk] = I_WORD_SIZE'(((r * 13) + (kk * 7) + 3) % (VALUE_MAX + 1));
                memModel.write_word(A_BASE_WORD + (r * K_DIM) + kk,
                               MEM_DATA_WIDTH'(a_matrix[r][kk]));
            end
        end

        for (int kk = 0; kk < K_DIM; kk++) begin
            for (int c = 0; c < N_DIM; c++) begin
                b_matrix[kk][c] = I_WORD_SIZE'(((kk * 5) + (c * 11) + 1) % (VALUE_MAX + 1));
                memModel.write_word(B_BASE_WORD + (kk * N_DIM) + c,
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

    initial begin
        longint unsigned macs;
        longint unsigned ops;
        longint unsigned modeled_bytes;
        real ops_per_cycle;
        real projected_gflops;
        real pe_util;
        real arithmetic_intensity;
        logic [MEM_DATA_WIDTH - 1:0] got;

        rst_l <= 1'b0;
        start <= 1'b0;
        repeat (4) @(posedge clk);
        rst_l <= 1'b1;
        initialize_problem();

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        fork
            begin
                repeat (1000000) @(posedge clk);
                $fatal(1, "Timed out waiting for sa_benchmark_test.");
            end

            begin
                wait (done);
            end
        join_any
        disable fork;

        assert(!error) else $fatal(1, "Accelerator reported an error.");

        for (int r = 0; r < M_DIM; r++) begin
            for (int c = 0; c < N_DIM; c++) begin
                got = memModel.read_word(C_BASE_WORD + (r * N_DIM) + c);
                assert(got[O_WORD_SIZE - 1:0] == expected_c[r][c])
                    else $fatal(1, "C[%0d][%0d] expected %0d, got %0d.",
                                r, c, expected_c[r][c], got[O_WORD_SIZE - 1:0]);
            end
        end

        macs = longint'(M_DIM) * longint'(N_DIM) * longint'(K_DIM);
        ops = 2 * macs;
        modeled_bytes = mem_bytes_read + mem_bytes_written;
        ops_per_cycle = (cycles == 0) ? 0.0 : real'(ops) / real'(cycles);
        projected_gflops = ops_per_cycle * real'(CLOCK_MHZ) / 1000.0;
        pe_util = (compute_cycles == 0) ? 0.0 :
                  real'(macs) / (real'(NUM_ROWS * NUM_COLS) * real'(compute_cycles));
        arithmetic_intensity = (modeled_bytes == 0) ? 0.0 :
                               real'(ops) / real'(modeled_bytes);

        $display("fpga_bench_header,rows,cols,k_tile,m,n,k,mem_read_lat,mem_write_lat,read_gap,write_gap,banks,row_words,row_hit,row_miss,clock_mhz,cycles,compute_cycles,mem_stall_cycles,reads,writes,bytes_read,bytes_written,tiles,ops_per_cycle,projected_gflops,pe_util,arithmetic_intensity");
        $display("fpga_bench,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%.6f,%.6f,%.6f",
                 NUM_ROWS, NUM_COLS, K_TILE, M_DIM, N_DIM, K_DIM,
                 READ_LATENCY, WRITE_LATENCY, READ_ACCEPT_GAP, WRITE_ACCEPT_GAP,
                 BANKS, ROW_WORDS, ROW_HIT_LATENCY, ROW_MISS_PENALTY, CLOCK_MHZ,
                 cycles, compute_cycles, memory_stall_cycles, accel_reads,
                 accel_writes, mem_bytes_read, mem_bytes_written, tile_count,
                 ops_per_cycle, projected_gflops, pe_util, arithmetic_intensity);

        $finish;
    end
endmodule : sa_benchmark_test
