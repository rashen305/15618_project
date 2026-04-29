/*
 * tiled_gemm_accelerator_test.sv: End-to-end memory-backed GEMM test.
 *
 * Runs the same 5×4×7 GEMM through three separate accelerator instances
 * (one per dataflow mode) in sequence, verifying all produce the correct C.
 *
 *   OS (output-stationary)   – default, accumulators local
 *   WS (weight-stationary)   – B cached; controller re-feeds each K-tile so
 *                              weight-reuse is not exercised, but correct
 *   NS (non-stationary/IS)   – A cached; same caveat as WS
 *
 * All three DUTs share one memory model; only the active DUT drives the bus.
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

    localparam int M_DIM       = 5;
    localparam int N_DIM       = 4;
    localparam int K_DIM       = 7;
    localparam int A_BASE_WORD = 0;
    localparam int B_BASE_WORD = 256;
    localparam int C_BASE_WORD = 512;

    logic clk, rst_l;

    // Shared problem parameters (same for all three DUTs).
    logic [DIM_WIDTH  - 1:0] m, n, k;
    logic [ADDR_WIDTH - 1:0] base_a, base_b, base_c;
    logic [DIM_WIDTH  - 1:0] stride_a, stride_b, stride_c;

    // Muxed memory bus (driven from the active DUT via the sel_* signals).
    logic mem_req_valid, mem_req_ready, mem_req_write;
    logic [ADDR_WIDTH     - 1:0] mem_req_addr;
    logic [MEM_DATA_WIDTH - 1:0] mem_req_wdata;
    logic [MEM_BYTES      - 1:0] mem_req_wstrb;
    logic mem_rsp_valid, mem_rsp_ready, mem_rsp_write;
    logic [ADDR_WIDTH     - 1:0] mem_rsp_addr;
    logic [MEM_DATA_WIDTH - 1:0] mem_rsp_rdata;

    // Per-DUT request outputs (DUT → test → MEM, muxed by sel_*).
    logic [2:0]               dut_req_valid_v, dut_req_write_v;
    logic [ADDR_WIDTH     - 1:0] dut_req_addr_v  [3];
    logic [MEM_DATA_WIDTH - 1:0] dut_req_wdata_v [3];
    logic [MEM_BYTES      - 1:0] dut_req_wstrb_v [3];

    // Per-DUT response-ready outputs (DUT → MEM via mux).
    logic [2:0] dut_rsp_rdy_v;

    // Active-DUT selector (0=OS, 1=WS, 2=NS).
    int unsigned sel;

    // Mux: active DUT drives the shared memory bus.
    always_comb begin
        mem_req_valid = dut_req_valid_v[sel];
        mem_req_write = dut_req_write_v[sel];
        mem_req_addr  = dut_req_addr_v [sel];
        mem_req_wdata = dut_req_wdata_v[sel];
        mem_req_wstrb = dut_req_wstrb_v[sel];
        mem_rsp_ready = dut_rsp_rdy_v  [sel];
    end

    // Per-DUT control.
    logic [2:0]  dut_start, dut_done, dut_error;
    logic [63:0] dut_cycles[3], dut_comp[3], dut_stall[3];
    logic [63:0] dut_reads [3], dut_writes[3], dut_tiles [3];

    // -----------------------------------------------------------------------
    // Memory model
    // -----------------------------------------------------------------------
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
        .o_cycle_count(),
        .o_read_count(),
        .o_write_count(),
        .o_bytes_read(),
        .o_bytes_written(),
        .o_stall_req_count()
    );

    // -----------------------------------------------------------------------
    // OS accelerator (DATAFLOW_MODE = SA_DATAFLOW_OS = 0)
    // -----------------------------------------------------------------------
    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),   .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),         .NUM_COLS(NUM_COLS),
        .K_TILE(K_TILE),             .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),     .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .DATAFLOW_MODE(SA_DATAFLOW_OS)
    ) os_dut (
        .clk, .rst_l,
        .i_start(dut_start[0]), .i_m(m), .i_n(n), .i_k(k),
        .i_base_a(base_a), .i_base_b(base_b), .i_base_c(base_c),
        .i_stride_a(stride_a), .i_stride_b(stride_b), .i_stride_c(stride_c),
        .o_mem_req_valid(dut_req_valid_v[0]),
        .i_mem_req_ready(mem_req_ready),
        .o_mem_req_write(dut_req_write_v[0]),
        .o_mem_req_addr(dut_req_addr_v[0]),
        .o_mem_req_wdata(dut_req_wdata_v[0]),
        .o_mem_req_wstrb(dut_req_wstrb_v[0]),
        .i_mem_rsp_valid(mem_rsp_valid),
        .o_mem_rsp_ready(dut_rsp_rdy_v[0]),
        .i_mem_rsp_write(mem_rsp_write),
        .i_mem_rsp_addr(mem_rsp_addr),
        .i_mem_rsp_rdata(mem_rsp_rdata),
        .o_busy(), .o_done(dut_done[0]), .o_error(dut_error[0]),
        .o_cycles(dut_cycles[0]), .o_compute_cycles(dut_comp[0]),
        .o_memory_stall_cycles(dut_stall[0]),
        .o_read_reqs(dut_reads[0]), .o_write_reqs(dut_writes[0]),
        .o_loaded_tile_count(), .o_tile_count(dut_tiles[0]),
        .o_prefetch_cycles(), .o_compute_wait_cycles()
    );

    // -----------------------------------------------------------------------
    // WS accelerator (DATAFLOW_MODE = SA_DATAFLOW_WS = 1)
    // -----------------------------------------------------------------------
    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),   .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),         .NUM_COLS(NUM_COLS),
        .K_TILE(K_TILE),             .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),     .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .DATAFLOW_MODE(SA_DATAFLOW_WS)
    ) ws_dut (
        .clk, .rst_l,
        .i_start(dut_start[1]), .i_m(m), .i_n(n), .i_k(k),
        .i_base_a(base_a), .i_base_b(base_b), .i_base_c(base_c),
        .i_stride_a(stride_a), .i_stride_b(stride_b), .i_stride_c(stride_c),
        .o_mem_req_valid(dut_req_valid_v[1]),
        .i_mem_req_ready(mem_req_ready),
        .o_mem_req_write(dut_req_write_v[1]),
        .o_mem_req_addr(dut_req_addr_v[1]),
        .o_mem_req_wdata(dut_req_wdata_v[1]),
        .o_mem_req_wstrb(dut_req_wstrb_v[1]),
        .i_mem_rsp_valid(mem_rsp_valid),
        .o_mem_rsp_ready(dut_rsp_rdy_v[1]),
        .i_mem_rsp_write(mem_rsp_write),
        .i_mem_rsp_addr(mem_rsp_addr),
        .i_mem_rsp_rdata(mem_rsp_rdata),
        .o_busy(), .o_done(dut_done[1]), .o_error(dut_error[1]),
        .o_cycles(dut_cycles[1]), .o_compute_cycles(dut_comp[1]),
        .o_memory_stall_cycles(dut_stall[1]),
        .o_read_reqs(dut_reads[1]), .o_write_reqs(dut_writes[1]),
        .o_loaded_tile_count(), .o_tile_count(dut_tiles[1]),
        .o_prefetch_cycles(), .o_compute_wait_cycles()
    );

    // -----------------------------------------------------------------------
    // NS accelerator (DATAFLOW_MODE = SA_DATAFLOW_NS = 2)
    // -----------------------------------------------------------------------
    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),   .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),         .NUM_COLS(NUM_COLS),
        .K_TILE(K_TILE),             .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),     .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .DATAFLOW_MODE(SA_DATAFLOW_NS)
    ) ns_dut (
        .clk, .rst_l,
        .i_start(dut_start[2]), .i_m(m), .i_n(n), .i_k(k),
        .i_base_a(base_a), .i_base_b(base_b), .i_base_c(base_c),
        .i_stride_a(stride_a), .i_stride_b(stride_b), .i_stride_c(stride_c),
        .o_mem_req_valid(dut_req_valid_v[2]),
        .i_mem_req_ready(mem_req_ready),
        .o_mem_req_write(dut_req_write_v[2]),
        .o_mem_req_addr(dut_req_addr_v[2]),
        .o_mem_req_wdata(dut_req_wdata_v[2]),
        .o_mem_req_wstrb(dut_req_wstrb_v[2]),
        .i_mem_rsp_valid(mem_rsp_valid),
        .o_mem_rsp_ready(dut_rsp_rdy_v[2]),
        .i_mem_rsp_write(mem_rsp_write),
        .i_mem_rsp_addr(mem_rsp_addr),
        .i_mem_rsp_rdata(mem_rsp_rdata),
        .o_busy(), .o_done(dut_done[2]), .o_error(dut_error[2]),
        .o_cycles(dut_cycles[2]), .o_compute_cycles(dut_comp[2]),
        .o_memory_stall_cycles(dut_stall[2]),
        .o_read_reqs(dut_reads[2]), .o_write_reqs(dut_writes[2]),
        .o_loaded_tile_count(), .o_tile_count(dut_tiles[2]),
        .o_prefetch_cycles(), .o_compute_wait_cycles()
    );

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    logic [I_WORD_SIZE - 1:0] a_matrix   [0:M_DIM - 1][0:K_DIM - 1];
    logic [I_WORD_SIZE - 1:0] b_matrix   [0:K_DIM - 1][0:N_DIM - 1];
    logic [O_WORD_SIZE - 1:0] expected_c [0:M_DIM - 1][0:N_DIM - 1];

    task automatic initialize_problem();
        logic [O_WORD_SIZE - 1:0] s;
        mem.clear_memory();
        for (int r = 0; r < M_DIM; r++)
            for (int kk = 0; kk < K_DIM; kk++) begin
                a_matrix[r][kk] = I_WORD_SIZE'(((r + 1) * (kk + 3)) % 17);
                mem.write_word(A_BASE_WORD + r * K_DIM + kk,
                               MEM_DATA_WIDTH'(a_matrix[r][kk]));
            end
        for (int kk = 0; kk < K_DIM; kk++)
            for (int c = 0; c < N_DIM; c++) begin
                b_matrix[kk][c] = I_WORD_SIZE'(((kk + 2) * (c + 5)) % 19);
                mem.write_word(B_BASE_WORD + kk * N_DIM + c,
                               MEM_DATA_WIDTH'(b_matrix[kk][c]));
            end
        for (int r = 0; r < M_DIM; r++)
            for (int c = 0; c < N_DIM; c++) begin
                s = '0;
                for (int kk = 0; kk < K_DIM; kk++)
                    s += O_WORD_SIZE'(a_matrix[r][kk]) * O_WORD_SIZE'(b_matrix[kk][c]);
                expected_c[r][c] = s;
            end
    endtask : initialize_problem

    task automatic clear_c_region();
        for (int w = 0; w < M_DIM * N_DIM; w++)
            mem.write_word(C_BASE_WORD + w, '0);
    endtask : clear_c_region

    task automatic check_c(input string name);
        logic [MEM_DATA_WIDTH - 1:0] got;
        for (int r = 0; r < M_DIM; r++)
            for (int c = 0; c < N_DIM; c++) begin
                got = mem.read_word(C_BASE_WORD + r * N_DIM + c);
                assert(got[O_WORD_SIZE - 1:0] == expected_c[r][c])
                    else $fatal(1, "[%s] C[%0d][%0d] expected %0d got %0d",
                                name, r, c, expected_c[r][c],
                                got[O_WORD_SIZE - 1:0]);
            end
    endtask : check_c

    task automatic run_mode(input int unsigned idx, input string name);
        $display("--- Running %s accelerator ---", name);
        clear_c_region();
        sel = idx;
        @(negedge clk);
        dut_start[idx] <= 1'b1;
        @(negedge clk);
        dut_start[idx] <= 1'b0;
        fork
            begin repeat (200000) @(posedge clk);
                  $fatal(1, "[%s] Timed out.", name); end
            begin wait (dut_done[idx]); end
        join_any
        disable fork;
        assert(!dut_error[idx]) else $fatal(1, "[%s] Error.", name);
        check_c(name);
        $display("%s: cycles=%0d compute=%0d mem_stall=%0d reads=%0d writes=%0d tiles=%0d",
                 name, dut_cycles[idx], dut_comp[idx], dut_stall[idx],
                 dut_reads[idx], dut_writes[idx], dut_tiles[idx]);
    endtask : run_mode

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        sel       = 0;
        dut_start = '0;
        m         = M_DIM;  n = N_DIM;  k = K_DIM;
        base_a    = ADDR_WIDTH'(A_BASE_WORD * MEM_BYTES);
        base_b    = ADDR_WIDTH'(B_BASE_WORD * MEM_BYTES);
        base_c    = ADDR_WIDTH'(C_BASE_WORD * MEM_BYTES);
        stride_a  = K_DIM;  stride_b = N_DIM;  stride_c = N_DIM;
        rst_l     = 1'b0;

        repeat (4) @(posedge clk);
        rst_l <= 1'b1;
        initialize_problem();
        @(posedge clk);

        run_mode(0, "OS");
        run_mode(1, "WS");
        run_mode(2, "NS");

        $display("\n");
        $display("***************************************************************************");
        $display("              TILED GEMM ACCELERATOR TESTS PASSED (OS / WS / NS)          ");
        $display("***************************************************************************");
        $display("\n");
        $finish;
    end
endmodule : tiled_gemm_accelerator_test
