/*
* tiled_gemm_accelerator_test.sv: End-to-end memory-backed GEMM test. This
* covers M/N edge tiles, multiple K tiles, memory latency, and final C writes.
*/

`timescale 1ns/1ns

`include "main_memory_model.sv"
`include "tiled_gemm_accelerator.sv"

module tiled_gemm_accelerator_test();
    localparam int I_WORD_SIZE    = 8;
    localparam int O_WORD_SIZE    = 32;
    localparam int NUM_ROWS       = 2;
    localparam int NUM_COLS       = 3;
    localparam int K_TILE         = 4;
    localparam int DIM_WIDTH      = 16;
    localparam int ADDR_WIDTH     = 18;
    localparam int MEM_DATA_WIDTH = 32;
    localparam int MEM_BYTES      = MEM_DATA_WIDTH / 8;
    localparam int DEPTH_WORDS    = 2048;

    localparam int M_DIM          = 5;
    localparam int N_DIM          = 4;
    localparam int K_DIM          = 7;
    localparam int A_BASE_WORD    = 0;
    localparam int B_BASE_WORD    = 256;
    localparam int C_BASE_WORD    = 512;

    logic clk;
    logic rst_l;

    logic start;
    logic [DIM_WIDTH - 1:0] m;
    logic [DIM_WIDTH - 1:0] n;
    logic [DIM_WIDTH - 1:0] k;
    logic [ADDR_WIDTH - 1:0] base_a;
    logic [ADDR_WIDTH - 1:0] base_b;
    logic [ADDR_WIDTH - 1:0] base_c;
    logic [DIM_WIDTH - 1:0] stride_a;
    logic [DIM_WIDTH - 1:0] stride_b;
    logic [DIM_WIDTH - 1:0] stride_c;

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
        .MAX_OUTSTANDING(8),
        .READ_LATENCY(8),
        .WRITE_LATENCY(4),
        .READ_ACCEPT_GAP(0),
        .WRITE_ACCEPT_GAP(0),
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
        .i_m(m),
        .i_n(n),
        .i_k(k),
        .i_base_a(base_a),
        .i_base_b(base_b),
        .i_base_c(base_c),
        .i_stride_a(stride_a),
        .i_stride_b(stride_b),
        .i_stride_c(stride_c),
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

        mem.clear_memory();

        for (int r = 0; r < M_DIM; r++) begin
            for (int kk = 0; kk < K_DIM; kk++) begin
                a_matrix[r][kk] = I_WORD_SIZE'(((r + 1) * (kk + 3)) % 17);
                mem.write_word(A_BASE_WORD + (r * K_DIM) + kk,
                               MEM_DATA_WIDTH'(a_matrix[r][kk]));
            end
        end

        for (int kk = 0; kk < K_DIM; kk++) begin
            for (int c = 0; c < N_DIM; c++) begin
                b_matrix[kk][c] = I_WORD_SIZE'(((kk + 2) * (c + 5)) % 19);
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

    initial begin
        logic [MEM_DATA_WIDTH - 1:0] got;

        rst_l    <= 1'b0;
        start    <= 1'b0;
        m        <= M_DIM;
        n        <= N_DIM;
        k        <= K_DIM;
        base_a   <= ADDR_WIDTH'(A_BASE_WORD * MEM_BYTES);
        base_b   <= ADDR_WIDTH'(B_BASE_WORD * MEM_BYTES);
        base_c   <= ADDR_WIDTH'(C_BASE_WORD * MEM_BYTES);
        stride_a <= K_DIM;
        stride_b <= N_DIM;
        stride_c <= N_DIM;

        repeat (4) @(posedge clk);
        rst_l <= 1'b1;
        initialize_problem();

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        fork
            begin
                repeat (200000) @(posedge clk);
                $fatal(1, "Timed out waiting for tiled GEMM accelerator.");
            end

            begin
                wait (done);
            end
        join_any
        disable fork;

        assert(!error) else $fatal(1, "Accelerator reported an error.");

        for (int r = 0; r < M_DIM; r++) begin
            for (int c = 0; c < N_DIM; c++) begin
                got = mem.read_word(C_BASE_WORD + (r * N_DIM) + c);
                assert(got[O_WORD_SIZE - 1:0] == expected_c[r][c])
                    else $fatal(1, "C[%0d][%0d] expected %0d, got %0d.",
                                r, c, expected_c[r][c], got[O_WORD_SIZE - 1:0]);
            end
        end

        $display("tiled_gemm cycles=%0d compute_cycles=%0d mem_stall_cycles=%0d reads=%0d writes=%0d tiles=%0d",
                 cycles, compute_cycles, memory_stall_cycles, accel_reads, accel_writes, tile_count);
        $display("\n");
        $display("***************************************************************************");
        $display("                    TILED GEMM ACCELERATOR TESTS PASSED                    ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : tiled_gemm_accelerator_test
