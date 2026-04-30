/*
 * Parameterized benchmark/test for systolic_gemm_engine.
 * Emits machine-readable CSV lines:
 *   engine_bench_header,...
 *   engine_bench,...
 */
`timescale 1ns/1ns

`include "main_memory_model.sv"
`include "systolic_gemm_engine.sv"

module systolic_gemm_engine_test #(
    parameter int I_WORD_SIZE          = 8,
    parameter int O_WORD_SIZE          = 32,
    parameter int DIM_WIDTH            = 16,
    parameter int ADDR_WIDTH           = 28,
    parameter int MEM_DATA_WIDTH       = 32,
    parameter int DEPTH_WORDS          = 1 << 20,
    parameter int VALUE_MAX            = 9,

    parameter int M_DIM                = 32,
    parameter int N_DIM                = 32,
    parameter int K_DIM                = 32,

    parameter int SELECT_SLOT          = 0,
    parameter bit ENABLE_DOUBLE_BUFFER = 1'b1,
    parameter int CLOCK_MHZ            = 100,

    parameter int SLOT0_ROWS           = 4,
    parameter int SLOT0_COLS           = 4,
    parameter int SLOT0_K_TILE         = 8,
    parameter int SLOT1_ROWS           = 8,
    parameter int SLOT1_COLS           = 4,
    parameter int SLOT1_K_TILE         = 8,
    parameter int SLOT2_ROWS           = 4,
    parameter int SLOT2_COLS           = 8,
    parameter int SLOT2_K_TILE         = 8,

    parameter int MAX_OUTSTANDING      = 16,
    parameter int READ_LATENCY         = 40,
    parameter int WRITE_LATENCY        = 20,
    parameter int READ_ACCEPT_GAP      = 0,
    parameter int WRITE_ACCEPT_GAP     = 0,
    parameter int BANKS                = 4,
    parameter int ROW_WORDS            = 1024,
    parameter int ROW_HIT_LATENCY      = 12,
    parameter int ROW_MISS_PENALTY     = 28,
    parameter bit MODEL_ROW_BUFFER     = 1'b1
)();
    localparam int MEM_BYTES = MEM_DATA_WIDTH / 8;
    localparam int A_BASE_WORD = 0;
    localparam int B_BASE_WORD = A_BASE_WORD + (M_DIM * K_DIM) + 1024;
    localparam int C_BASE_WORD = B_BASE_WORD + (K_DIM * N_DIM) + 1024;

    logic clk;
    logic rst_l;
    logic start;
    logic [1:0] array_select;

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
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .READ_LATENCY(READ_LATENCY),
        .WRITE_LATENCY(WRITE_LATENCY),
        .READ_ACCEPT_GAP(READ_ACCEPT_GAP),
        .WRITE_ACCEPT_GAP(WRITE_ACCEPT_GAP),
        .BANKS(BANKS),
        .ROW_WORDS(ROW_WORDS),
        .ROW_HIT_LATENCY(ROW_HIT_LATENCY),
        .ROW_MISS_PENALTY(ROW_MISS_PENALTY),
        .MODEL_ROW_BUFFER(MODEL_ROW_BUFFER)
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
        .ENABLE_DOUBLE_BUFFER(ENABLE_DOUBLE_BUFFER),
        .SLOT0_ROWS(SLOT0_ROWS),
        .SLOT0_COLS(SLOT0_COLS),
        .SLOT0_K_TILE(SLOT0_K_TILE),
        .SLOT1_ROWS(SLOT1_ROWS),
        .SLOT1_COLS(SLOT1_COLS),
        .SLOT1_K_TILE(SLOT1_K_TILE),
        .SLOT2_ROWS(SLOT2_ROWS),
        .SLOT2_COLS(SLOT2_COLS),
        .SLOT2_K_TILE(SLOT2_K_TILE)
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

    function automatic int selected_rows();
        case (SELECT_SLOT)
            0: selected_rows = SLOT0_ROWS;
            1: selected_rows = SLOT1_ROWS;
            2: selected_rows = SLOT2_ROWS;
            default: selected_rows = SLOT0_ROWS;
        endcase
    endfunction

    function automatic int selected_cols();
        case (SELECT_SLOT)
            0: selected_cols = SLOT0_COLS;
            1: selected_cols = SLOT1_COLS;
            2: selected_cols = SLOT2_COLS;
            default: selected_cols = SLOT0_COLS;
        endcase
    endfunction

    function automatic int selected_ktile();
        case (SELECT_SLOT)
            0: selected_ktile = SLOT0_K_TILE;
            1: selected_ktile = SLOT1_K_TILE;
            2: selected_ktile = SLOT2_K_TILE;
            default: selected_ktile = SLOT0_K_TILE;
        endcase
    endfunction

    task automatic initialize_problem();
        logic [O_WORD_SIZE - 1:0] sum;
        mem.clear_memory();

        for (int r = 0; r < M_DIM; r++) begin
            for (int kk = 0; kk < K_DIM; kk++) begin
                a_matrix[r][kk] = I_WORD_SIZE'((((r + 3) * (kk + 5)) % VALUE_MAX) + 1);
                mem.write_word(A_BASE_WORD + (r * K_DIM) + kk,
                               MEM_DATA_WIDTH'(a_matrix[r][kk]));
            end
        end

        for (int kk = 0; kk < K_DIM; kk++) begin
            for (int c = 0; c < N_DIM; c++) begin
                b_matrix[kk][c] = I_WORD_SIZE'((((kk + 7) * (c + 2)) % VALUE_MAX) + 1);
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
    endtask

    task automatic verify_result();
        logic [MEM_DATA_WIDTH - 1:0] got;
        for (int r = 0; r < M_DIM; r++) begin
            for (int c = 0; c < N_DIM; c++) begin
                got = mem.read_word(C_BASE_WORD + (r * N_DIM) + c);
                assert(got[O_WORD_SIZE - 1:0] == expected_c[r][c])
                    else $fatal(1, "C[%0d][%0d] expected %0d, got %0d.",
                                r, c, expected_c[r][c], got[O_WORD_SIZE - 1:0]);
            end
        end
    endtask

    task automatic print_csv();
        int rows;
        int cols;
        int ktile;
        longint unsigned macs;
        longint unsigned ops;
        longint unsigned modeled_bytes;
        longint unsigned peak_macs_per_cycle;
        longint unsigned peak_ops_per_cycle;
        longint unsigned total_array_slots;
        real effective_macs_per_cycle;
        real effective_ops_per_cycle;
        real compute_macs_per_cycle;
        real compute_ops_per_cycle;
        real effective_gops;
        real compute_gops;
        real peak_gops;
        real overall_pe_util;
        real compute_pe_util;
        real per_pe_effective_ops_per_cycle;
        real per_pe_compute_ops_per_cycle;
        real arithmetic_intensity;
        real mem_bytes_per_cycle;
        real mem_read_bytes_per_cycle;
        real mem_write_bytes_per_cycle;
        real memory_stall_frac;
        real compute_frac;
        real prefetch_frac;
        real wait_frac;

        rows = selected_rows();
        cols = selected_cols();
        ktile = selected_ktile();

        macs = longint'(M_DIM) * longint'(N_DIM) * longint'(K_DIM);
        ops = 2 * macs;
        modeled_bytes = mem_bytes_read + mem_bytes_written;
        peak_macs_per_cycle = rows * cols;
        peak_ops_per_cycle = 2 * peak_macs_per_cycle;
        total_array_slots = peak_macs_per_cycle * cycles;

        effective_macs_per_cycle = (cycles == 0) ? 0.0 : real'(macs) / real'(cycles);
        effective_ops_per_cycle = (cycles == 0) ? 0.0 : real'(ops) / real'(cycles);
        compute_macs_per_cycle = (compute_cycles == 0) ? 0.0 : real'(macs) / real'(compute_cycles);
        compute_ops_per_cycle = (compute_cycles == 0) ? 0.0 : real'(ops) / real'(compute_cycles);

        effective_gops = effective_ops_per_cycle * real'(CLOCK_MHZ) / 1000.0;
        compute_gops = compute_ops_per_cycle * real'(CLOCK_MHZ) / 1000.0;
        peak_gops = real'(peak_ops_per_cycle) * real'(CLOCK_MHZ) / 1000.0;

        overall_pe_util = (total_array_slots == 0) ? 0.0 : real'(macs) / real'(total_array_slots);
        compute_pe_util = (compute_cycles == 0) ? 0.0 : real'(macs) / (real'(rows * cols) * real'(compute_cycles));
        per_pe_effective_ops_per_cycle = (rows * cols == 0) ? 0.0 : effective_ops_per_cycle / real'(rows * cols);
        per_pe_compute_ops_per_cycle = (rows * cols == 0) ? 0.0 : compute_ops_per_cycle / real'(rows * cols);
        arithmetic_intensity = (modeled_bytes == 0) ? 0.0 : real'(ops) / real'(modeled_bytes);
        mem_bytes_per_cycle = (cycles == 0) ? 0.0 : real'(modeled_bytes) / real'(cycles);
        mem_read_bytes_per_cycle = (cycles == 0) ? 0.0 : real'(mem_bytes_read) / real'(cycles);
        mem_write_bytes_per_cycle = (cycles == 0) ? 0.0 : real'(mem_bytes_written) / real'(cycles);
        memory_stall_frac = (cycles == 0) ? 0.0 : real'(memory_stall_cycles) / real'(cycles);
        compute_frac = (cycles == 0) ? 0.0 : real'(compute_cycles) / real'(cycles);
        prefetch_frac = (cycles == 0) ? 0.0 : real'(prefetch_cycles) / real'(cycles);
        wait_frac = (cycles == 0) ? 0.0 : real'(compute_wait_cycles) / real'(cycles);

        $display("engine_bench_header,test_kind,slot,rows,cols,k_tile,m,n,k,double_buffer,clock_mhz,mem_read_lat,mem_write_lat,read_gap,write_gap,max_outstanding,banks,row_words,row_hit,row_miss,row_buffer,cycles,compute_cycles,memory_stall_cycles,prefetch_cycles,compute_wait_cycles,mem_cycles,reads,writes,mem_reads,mem_writes,bytes_read,bytes_written,modeled_bytes,loaded_k_tiles,output_tiles,macs,ops,peak_macs_per_cycle,peak_ops_per_cycle,effective_macs_per_cycle,effective_ops_per_cycle,compute_macs_per_cycle,compute_ops_per_cycle,effective_gops,compute_gops,peak_gops,overall_pe_util,compute_pe_util,per_pe_effective_ops_per_cycle,per_pe_compute_ops_per_cycle,arithmetic_intensity,mem_bytes_per_cycle,mem_read_bytes_per_cycle,mem_write_bytes_per_cycle,memory_stall_frac,compute_frac,prefetch_frac,compute_wait_frac");
        $display("engine_bench,engine,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                 SELECT_SLOT, rows, cols, ktile, M_DIM, N_DIM, K_DIM,
                 ENABLE_DOUBLE_BUFFER, CLOCK_MHZ, READ_LATENCY, WRITE_LATENCY,
                 READ_ACCEPT_GAP, WRITE_ACCEPT_GAP, MAX_OUTSTANDING, BANKS,
                 ROW_WORDS, ROW_HIT_LATENCY, ROW_MISS_PENALTY, MODEL_ROW_BUFFER,
                 cycles, compute_cycles, memory_stall_cycles, prefetch_cycles,
                 compute_wait_cycles, mem_cycles, read_reqs, write_reqs, mem_reads,
                 mem_writes, mem_bytes_read, mem_bytes_written, modeled_bytes,
                 loaded_tile_count, tile_count, macs, ops, peak_macs_per_cycle,
                 peak_ops_per_cycle, effective_macs_per_cycle, effective_ops_per_cycle,
                 compute_macs_per_cycle, compute_ops_per_cycle, effective_gops,
                 compute_gops, peak_gops, overall_pe_util, compute_pe_util,
                 per_pe_effective_ops_per_cycle, per_pe_compute_ops_per_cycle,
                 arithmetic_intensity, mem_bytes_per_cycle, mem_read_bytes_per_cycle,
                 mem_write_bytes_per_cycle, memory_stall_frac, compute_frac,
                 prefetch_frac, wait_frac);
    endtask

    initial begin
        if ((SELECT_SLOT < 0) || (SELECT_SLOT > 2)) begin
            $fatal(1, "SELECT_SLOT must be 0, 1, or 2.");
        end

        rst_l <= 1'b0;
        start <= 1'b0;
        array_select <= SELECT_SLOT[1:0];

        repeat (4) @(posedge clk);
        rst_l <= 1'b1;
        initialize_problem();

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        fork
            // begin
            //     repeat (1000000000) @(posedge clk);
            //     $fatal(1, "Timed out waiting for systolic_gemm_engine.");
            // end
            begin
                wait (done);
            end
        join_any
        disable fork;

        assert(!error) else $fatal(1, "Engine reported error.");
        verify_result();
        print_csv();
        $finish;
    end
endmodule
