/*
* tiled_gemm_accelerator.sv: Memory-backed GEMM controller around the systolic
* array. The controller supports M/N output tiling, K tiling, and optional
* double buffering so the next K tile can be prefetched while the array drains
* the current K tile.
*/

`ifndef _TILED_GEMM_ACCELERATOR
`define _TILED_GEMM_ACCELERATOR

`include "sa_params.sv"
`include "sa_wavefront_feeder.sv"
`include "systolic_array.sv"

module tiled_gemm_accelerator
    #(parameter int I_WORD_SIZE          = MATRIX_WORD_SIZE,
      parameter int O_WORD_SIZE          = 2 * I_WORD_SIZE,
      parameter int NUM_ROWS             = SA_ROWS,
      parameter int NUM_COLS             = SA_COLS,
      parameter int K_TILE               = NUM_COLS,
      parameter int DIM_WIDTH            = 16,
      parameter int ADDR_WIDTH           = 32,
      parameter int MEM_DATA_WIDTH       = O_WORD_SIZE,
      parameter bit ENABLE_DOUBLE_BUFFER = 1'b1)
    (input  logic                         clk,
     input  logic                         rst_l,

     input  logic                         i_start,
     input  logic [DIM_WIDTH - 1:0]       i_m,
     input  logic [DIM_WIDTH - 1:0]       i_n,
     input  logic [DIM_WIDTH - 1:0]       i_k,
     input  logic [ADDR_WIDTH - 1:0]      i_base_a,
     input  logic [ADDR_WIDTH - 1:0]      i_base_b,
     input  logic [ADDR_WIDTH - 1:0]      i_base_c,
     input  logic [DIM_WIDTH - 1:0]       i_stride_a,
     input  logic [DIM_WIDTH - 1:0]       i_stride_b,
     input  logic [DIM_WIDTH - 1:0]       i_stride_c,

     output logic                         o_mem_req_valid,
     input  logic                         i_mem_req_ready,
     output logic                         o_mem_req_write,
     output logic [ADDR_WIDTH - 1:0]      o_mem_req_addr,
     output logic [MEM_DATA_WIDTH - 1:0]  o_mem_req_wdata,
     output logic [(MEM_DATA_WIDTH / 8) - 1:0] o_mem_req_wstrb,

     input  logic                         i_mem_rsp_valid,
     output logic                         o_mem_rsp_ready,
     input  logic                         i_mem_rsp_write,
     input  logic [ADDR_WIDTH - 1:0]      i_mem_rsp_addr,
     input  logic [MEM_DATA_WIDTH - 1:0]  i_mem_rsp_rdata,

     output logic                         o_busy,
     output logic                         o_done,
     output logic                         o_error,
     output logic [63:0]                  o_cycles,
     output logic [63:0]                  o_compute_cycles,
     output logic [63:0]                  o_memory_stall_cycles,
     output logic [63:0]                  o_prefetch_cycles,
     output logic [63:0]                  o_compute_wait_cycles,
     output logic [63:0]                  o_read_reqs,
     output logic [63:0]                  o_write_reqs,
     output logic [63:0]                  o_loaded_tile_count,
     output logic [63:0]                  o_tile_count);

    localparam int MEM_BYTES = MEM_DATA_WIDTH / 8;
    localparam int K_W       = (K_TILE <= 1) ? 1 : $clog2(K_TILE + 1);

    typedef enum logic [3:0] {
        S_IDLE,
        S_TILE_BEGIN,
        S_WAIT_FIRST_LOAD,
        S_START_COMPUTE,
        S_RUN,
        S_WAIT_BUFFER,
        S_WRITE_REQ,
        S_WRITE_WAIT,
        S_NEXT_TILE,
        S_DONE,
        S_ERROR
    } state_t;

    typedef enum logic [2:0] {
        L_IDLE,
        L_A_REQ,
        L_A_WAIT,
        L_B_REQ,
        L_B_WAIT
    } load_state_t;

    state_t      state;
    load_state_t load_state;

    logic [I_WORD_SIZE - 1:0] tile_a [0:1][0:NUM_ROWS - 1][0:K_TILE - 1];
    logic [I_WORD_SIZE - 1:0] tile_b [0:1][0:K_TILE - 1][0:NUM_COLS - 1];
    logic [I_WORD_SIZE - 1:0] compute_tile_a [0:NUM_ROWS - 1][0:K_TILE - 1];
    logic [I_WORD_SIZE - 1:0] compute_tile_b [0:K_TILE - 1][0:NUM_COLS - 1];

    logic                     buffer_valid [0:1];
    int unsigned              buffer_k_base [0:1];
    int unsigned              buffer_k_span [0:1];

    logic [NUM_ROWS - 1:0]    rows_valid;
    logic [NUM_COLS - 1:0]    cols_valid;
    logic [I_WORD_SIZE - 1:0] feeder_cell_data [0:NUM_ROWS + NUM_COLS - 1];
    logic [O_WORD_SIZE - 1:0] array_cell_data [0:NUM_ROWS - 1][0:NUM_COLS - 1];
    logic                     feeder_start;
    logic                     feeder_done;
    logic                     feeder_busy;
    logic                     array_done;
    logic                     array_clear;
    logic [K_W - 1:0]         feeder_k_dim;

    int unsigned              m_dim;
    int unsigned              n_dim;
    int unsigned              k_dim;
    int unsigned              stride_a;
    int unsigned              stride_b;
    int unsigned              stride_c;
    logic [ADDR_WIDTH - 1:0]  base_a;
    logic [ADDR_WIDTH - 1:0]  base_b;
    logic [ADDR_WIDTH - 1:0]  base_c;

    int unsigned              row_base;
    int unsigned              col_base;
    int unsigned              next_k_to_load;
    int unsigned              compute_buf;
    int unsigned              compute_k_base;
    int unsigned              compute_k_span;

    int unsigned              load_buf;
    int unsigned              load_k_base;
    int unsigned              load_r;
    int unsigned              load_k;
    int unsigned              load_c;
    int unsigned              write_r;
    int unsigned              write_c;

    initial begin
        if ((MEM_DATA_WIDTH % 8) != 0) begin
            $fatal(1, "tiled_gemm_accelerator requires byte-aligned MEM_DATA_WIDTH.");
        end

        if (MEM_DATA_WIDTH < O_WORD_SIZE) begin
            $fatal(1, "tiled_gemm_accelerator requires MEM_DATA_WIDTH >= O_WORD_SIZE.");
        end

        if (MEM_DATA_WIDTH < I_WORD_SIZE) begin
            $fatal(1, "tiled_gemm_accelerator requires MEM_DATA_WIDTH >= I_WORD_SIZE.");
        end

        if ((NUM_ROWS < 1) || (NUM_COLS < 1) || (K_TILE < 1)) begin
            $fatal(1, "tiled_gemm_accelerator requires NUM_ROWS, NUM_COLS, and K_TILE >= 1.");
        end
    end

    sa_wavefront_feeder #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS),
        .K_DIM(K_TILE)
    ) feeder (
        .clk,
        .rst_l,
        .i_start(feeder_start),
        .i_k_dim(feeder_k_dim),
        .i_matrixA(compute_tile_a),
        .i_matrixB(compute_tile_b),
        .o_rowsValid(rows_valid),
        .o_colsValid(cols_valid),
        .o_cellData(feeder_cell_data),
        .o_busy(feeder_busy),
        .o_done(feeder_done)
    );

    ns_systolic_array #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(NUM_ROWS),
        .NUM_COLS(NUM_COLS)
    ) array (
        .clk,
        .rst_l,
        .i_rowsValid(rows_valid),
        .i_colsValid(cols_valid),
        .i_cellData(feeder_cell_data),
        .i_feederDone(feeder_done),
        .i_acc_clear(array_clear),
        .o_cellData(array_cell_data),
        .o_compDone(array_done)
    );

    function automatic int unsigned k_span_at(input int unsigned k_base);
        int unsigned remaining;

        remaining = k_dim - k_base;
        k_span_at = (remaining < K_TILE) ? remaining : K_TILE;
    endfunction : k_span_at

    function automatic int unsigned other_buf(input int unsigned buf);
        other_buf = (buf == 0) ? 1 : 0;
    endfunction : other_buf

    function automatic bit load_a_in_bounds();
        load_a_in_bounds = ((row_base + load_r) < m_dim) &&
                           ((load_k_base + load_k) < k_dim);
    endfunction : load_a_in_bounds

    function automatic bit load_b_in_bounds();
        load_b_in_bounds = ((load_k_base + load_k) < k_dim) &&
                           ((col_base + load_c) < n_dim);
    endfunction : load_b_in_bounds

    function automatic bit c_in_bounds();
        c_in_bounds = ((row_base + write_r) < m_dim) &&
                      ((col_base + write_c) < n_dim);
    endfunction : c_in_bounds

    function automatic bit load_a_last();
        load_a_last = (load_r == (NUM_ROWS - 1)) && (load_k == (K_TILE - 1));
    endfunction : load_a_last

    function automatic bit load_b_last();
        load_b_last = (load_k == (K_TILE - 1)) && (load_c == (NUM_COLS - 1));
    endfunction : load_b_last

    function automatic bit write_last();
        write_last = (write_r == (NUM_ROWS - 1)) && (write_c == (NUM_COLS - 1));
    endfunction : write_last

    function automatic bit compute_is_final_k();
        compute_is_final_k = ((compute_k_base + compute_k_span) >= k_dim);
    endfunction : compute_is_final_k

    function automatic logic [ADDR_WIDTH - 1:0] element_addr(
        input logic [ADDR_WIDTH - 1:0] base,
        input int unsigned row,
        input int unsigned col,
        input int unsigned stride
    );
        longint unsigned offset_words;
        longint unsigned offset_bytes;

        offset_words = (longint'(row) * longint'(stride)) + longint'(col);
        offset_bytes = longint'(base) + (offset_words * MEM_BYTES);
        element_addr = ADDR_WIDTH'(offset_bytes);
    endfunction : element_addr

    task automatic clear_buffer(input int unsigned buf);
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int kk = 0; kk < K_TILE; kk++) begin
                tile_a[buf][r][kk] <= '0;
            end
        end

        for (int kk = 0; kk < K_TILE; kk++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                tile_b[buf][kk][c] <= '0;
            end
        end
    endtask : clear_buffer

    task automatic clear_all_buffers();
        clear_buffer(0);
        clear_buffer(1);
        buffer_valid[0]  <= 1'b0;
        buffer_valid[1]  <= 1'b0;
        buffer_k_base[0] <= 0;
        buffer_k_base[1] <= 0;
        buffer_k_span[0] <= 0;
        buffer_k_span[1] <= 0;
    endtask : clear_all_buffers

    task automatic start_load(input int unsigned buf,
                              input int unsigned k_base);
        clear_buffer(buf);
        buffer_valid[buf]  <= 1'b0;
        buffer_k_base[buf] <= k_base;
        buffer_k_span[buf] <= k_span_at(k_base);
        load_buf           <= buf;
        load_k_base        <= k_base;
        load_r             <= 0;
        load_k             <= 0;
        load_c             <= 0;
        load_state         <= L_A_REQ;
    endtask : start_load

    task automatic finish_load();
        buffer_valid[load_buf] <= 1'b1;
        load_state             <= L_IDLE;
        o_loaded_tile_count    <= o_loaded_tile_count + 64'd1;
    endtask : finish_load

    task automatic advance_a_load();
        if (load_k == (K_TILE - 1)) begin
            load_k <= 0;
            load_r <= load_r + 1;
        end

        else begin
            load_k <= load_k + 1;
        end
    endtask : advance_a_load

    task automatic advance_b_load();
        if (load_c == (NUM_COLS - 1)) begin
            load_c <= 0;
            load_k <= load_k + 1;
        end

        else begin
            load_c <= load_c + 1;
        end
    endtask : advance_b_load

    task automatic advance_write();
        if (write_c == (NUM_COLS - 1)) begin
            write_c <= 0;
            write_r <= write_r + 1;
        end

        else begin
            write_c <= write_c + 1;
        end
    endtask : advance_write

    task automatic select_compute_buffer(input int unsigned buf);
        compute_buf       <= buf;
        compute_k_base    <= buffer_k_base[buf];
        compute_k_span    <= buffer_k_span[buf];
        buffer_valid[buf] <= 1'b0;
    endtask : select_compute_buffer

    task automatic maybe_start_prefetch(input int unsigned free_buf);
        if (ENABLE_DOUBLE_BUFFER && (load_state == L_IDLE) && (next_k_to_load < k_dim)) begin
            start_load(free_buf, next_k_to_load);
            next_k_to_load <= next_k_to_load + K_TILE;
        end
    endtask : maybe_start_prefetch

    always_comb begin
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int kk = 0; kk < K_TILE; kk++) begin
                compute_tile_a[r][kk] = tile_a[compute_buf][r][kk];
            end
        end

        for (int kk = 0; kk < K_TILE; kk++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                compute_tile_b[kk][c] = tile_b[compute_buf][kk][c];
            end
        end
    end

    always_comb begin
        feeder_start      = (state == S_START_COMPUTE);
        array_clear       = (state == S_TILE_BEGIN);
        feeder_k_dim      = K_W'(compute_k_span);
        o_busy            = (state != S_IDLE);
        o_mem_req_valid   = 1'b0;
        o_mem_req_write   = 1'b0;
        o_mem_req_addr    = '0;
        o_mem_req_wdata   = '0;
        o_mem_req_wstrb   = '0;
        o_mem_rsp_ready   = (load_state == L_A_WAIT) ||
                            (load_state == L_B_WAIT) ||
                            (state == S_WRITE_WAIT);

        if (state == S_WRITE_REQ) begin
            if (c_in_bounds()) begin
                o_mem_req_valid = 1'b1;
                o_mem_req_write = 1'b1;
                o_mem_req_addr  = element_addr(base_c,
                                               row_base + write_r,
                                               col_base + write_c,
                                               stride_c);
                o_mem_req_wdata[O_WORD_SIZE - 1:0] = array_cell_data[write_r][write_c];
                o_mem_req_wstrb = '1;
            end
        end

        else begin
            unique case (load_state)
                L_A_REQ: begin
                    if (load_a_in_bounds()) begin
                        o_mem_req_valid = 1'b1;
                        o_mem_req_addr  = element_addr(base_a,
                                                       row_base + load_r,
                                                       load_k_base + load_k,
                                                       stride_a);
                    end
                end

                L_B_REQ: begin
                    if (load_b_in_bounds()) begin
                        o_mem_req_valid = 1'b1;
                        o_mem_req_addr  = element_addr(base_b,
                                                       load_k_base + load_k,
                                                       col_base + load_c,
                                                       stride_b);
                    end
                end

                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            state                 <= S_IDLE;
            load_state            <= L_IDLE;
            o_done                <= 1'b0;
            o_error               <= 1'b0;
            o_cycles              <= '0;
            o_compute_cycles      <= '0;
            o_memory_stall_cycles <= '0;
            o_prefetch_cycles     <= '0;
            o_compute_wait_cycles <= '0;
            o_read_reqs           <= '0;
            o_write_reqs          <= '0;
            o_loaded_tile_count   <= '0;
            o_tile_count          <= '0;
            m_dim                 <= 0;
            n_dim                 <= 0;
            k_dim                 <= 0;
            stride_a              <= 0;
            stride_b              <= 0;
            stride_c              <= 0;
            base_a                <= '0;
            base_b                <= '0;
            base_c                <= '0;
            row_base              <= 0;
            col_base              <= 0;
            next_k_to_load        <= 0;
            compute_buf           <= 0;
            compute_k_base        <= 0;
            compute_k_span        <= 0;
            load_buf              <= 0;
            load_k_base           <= 0;
            load_r                <= 0;
            load_k                <= 0;
            load_c                <= 0;
            write_r               <= 0;
            write_c               <= 0;
            clear_all_buffers();
        end

        else begin
            o_done <= 1'b0;

            if (state != S_IDLE) begin
                o_cycles <= o_cycles + 64'd1;
            end

            if (state == S_RUN) begin
                o_compute_cycles <= o_compute_cycles + 64'd1;
            end

            if ((state == S_RUN) && (load_state != L_IDLE)) begin
                o_prefetch_cycles <= o_prefetch_cycles + 64'd1;
            end

            if (state == S_WAIT_BUFFER) begin
                o_compute_wait_cycles <= o_compute_wait_cycles + 64'd1;
            end

            unique case (load_state)
                L_IDLE: begin
                end

                L_A_REQ: begin
                    if (!load_a_in_bounds()) begin
                        if (load_a_last()) begin
                            load_r     <= 0;
                            load_k     <= 0;
                            load_state <= L_B_REQ;
                        end

                        else begin
                            advance_a_load();
                        end
                    end

                    else if (i_mem_req_ready) begin
                        o_read_reqs <= o_read_reqs + 64'd1;
                        load_state  <= L_A_WAIT;
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                L_A_WAIT: begin
                    if (i_mem_rsp_valid && !i_mem_rsp_write) begin
                        tile_a[load_buf][load_r][load_k] <= i_mem_rsp_rdata[I_WORD_SIZE - 1:0];

                        if (load_a_last()) begin
                            load_r     <= 0;
                            load_k     <= 0;
                            load_state <= L_B_REQ;
                        end

                        else begin
                            advance_a_load();
                            load_state <= L_A_REQ;
                        end
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                L_B_REQ: begin
                    if (!load_b_in_bounds()) begin
                        if (load_b_last()) begin
                            load_k <= 0;
                            load_c <= 0;
                            finish_load();
                        end

                        else begin
                            advance_b_load();
                        end
                    end

                    else if (i_mem_req_ready) begin
                        o_read_reqs <= o_read_reqs + 64'd1;
                        load_state  <= L_B_WAIT;
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                L_B_WAIT: begin
                    if (i_mem_rsp_valid && !i_mem_rsp_write) begin
                        tile_b[load_buf][load_k][load_c] <= i_mem_rsp_rdata[I_WORD_SIZE - 1:0];

                        if (load_b_last()) begin
                            load_k <= 0;
                            load_c <= 0;
                            finish_load();
                        end

                        else begin
                            advance_b_load();
                            load_state <= L_B_REQ;
                        end
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                default: begin
                    load_state <= L_IDLE;
                    o_error    <= 1'b1;
                    state      <= S_ERROR;
                end
            endcase

            unique case (state)
                S_IDLE: begin
                    if (i_start) begin
                        o_cycles              <= '0;
                        o_compute_cycles      <= '0;
                        o_memory_stall_cycles <= '0;
                        o_prefetch_cycles     <= '0;
                        o_compute_wait_cycles <= '0;
                        o_read_reqs           <= '0;
                        o_write_reqs          <= '0;
                        o_loaded_tile_count   <= '0;
                        o_tile_count          <= '0;
                        o_error               <= 1'b0;

                        if ((i_m == '0) || (i_n == '0) || (i_k == '0)) begin
                            o_error <= 1'b1;
                            state   <= S_ERROR;
                        end

                        else begin
                            m_dim          <= int'(i_m);
                            n_dim          <= int'(i_n);
                            k_dim          <= int'(i_k);
                            stride_a       <= (i_stride_a == '0) ? int'(i_k) : int'(i_stride_a);
                            stride_b       <= (i_stride_b == '0) ? int'(i_n) : int'(i_stride_b);
                            stride_c       <= (i_stride_c == '0) ? int'(i_n) : int'(i_stride_c);
                            base_a         <= i_base_a;
                            base_b         <= i_base_b;
                            base_c         <= i_base_c;
                            row_base       <= 0;
                            col_base       <= 0;
                            next_k_to_load <= 0;
                            state          <= S_TILE_BEGIN;
                        end
                    end
                end

                S_TILE_BEGIN: begin
                    clear_all_buffers();
                    compute_buf    <= 0;
                    compute_k_base <= 0;
                    compute_k_span <= 0;
                    write_r        <= 0;
                    write_c        <= 0;
                    start_load(0, 0);
                    next_k_to_load <= K_TILE;
                    state          <= S_WAIT_FIRST_LOAD;
                end

                S_WAIT_FIRST_LOAD: begin
                    if (buffer_valid[0]) begin
                        select_compute_buffer(0);

                        if (ENABLE_DOUBLE_BUFFER && (K_TILE < k_dim)) begin
                            start_load(1, K_TILE);
                            next_k_to_load <= K_TILE + K_TILE;
                        end

                        state <= S_START_COMPUTE;
                    end
                end

                S_START_COMPUTE: begin
                    state <= S_RUN;
                end

                S_RUN: begin
                    if (array_done) begin
                        if (compute_is_final_k()) begin
                            write_r <= 0;
                            write_c <= 0;
                            state   <= S_WRITE_REQ;
                        end

                        else if (buffer_valid[other_buf(compute_buf)]) begin
                            maybe_start_prefetch(compute_buf);
                            select_compute_buffer(other_buf(compute_buf));
                            state <= S_START_COMPUTE;
                        end

                        else begin
                            if (!ENABLE_DOUBLE_BUFFER && (load_state == L_IDLE)) begin
                                start_load(other_buf(compute_buf), compute_k_base + compute_k_span);
                                next_k_to_load <= compute_k_base + compute_k_span + K_TILE;
                            end

                            state <= S_WAIT_BUFFER;
                        end
                    end
                end

                S_WAIT_BUFFER: begin
                    if (buffer_valid[other_buf(compute_buf)]) begin
                        maybe_start_prefetch(compute_buf);
                        select_compute_buffer(other_buf(compute_buf));
                        state <= S_START_COMPUTE;
                    end

                    else if (!ENABLE_DOUBLE_BUFFER && (load_state == L_IDLE)) begin
                        start_load(other_buf(compute_buf), compute_k_base + compute_k_span);
                        next_k_to_load <= compute_k_base + compute_k_span + K_TILE;
                    end
                end

                S_WRITE_REQ: begin
                    if (!c_in_bounds()) begin
                        if (write_last()) begin
                            state <= S_NEXT_TILE;
                        end

                        else begin
                            advance_write();
                        end
                    end

                    else if (i_mem_req_ready) begin
                        o_write_reqs <= o_write_reqs + 64'd1;
                        state        <= S_WRITE_WAIT;
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                S_WRITE_WAIT: begin
                    if (i_mem_rsp_valid && i_mem_rsp_write) begin
                        if (write_last()) begin
                            state <= S_NEXT_TILE;
                        end

                        else begin
                            advance_write();
                            state <= S_WRITE_REQ;
                        end
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                S_NEXT_TILE: begin
                    o_tile_count <= o_tile_count + 64'd1;

                    if ((col_base + NUM_COLS) < n_dim) begin
                        col_base <= col_base + NUM_COLS;
                        state    <= S_TILE_BEGIN;
                    end

                    else if ((row_base + NUM_ROWS) < m_dim) begin
                        row_base <= row_base + NUM_ROWS;
                        col_base <= 0;
                        state    <= S_TILE_BEGIN;
                    end

                    else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    o_done <= 1'b1;
                    state  <= S_IDLE;
                end

                S_ERROR: begin
                    o_done <= 1'b1;
                    state  <= S_IDLE;
                end

                default: begin
                    state   <= S_ERROR;
                    o_error <= 1'b1;
                end
            endcase
        end
    end

endmodule : tiled_gemm_accelerator
`endif // _TILED_GEMM_ACCELERATOR
