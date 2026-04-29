/*
* tiled_gemm_accelerator.sv: Memory-backed GEMM controller around the systolic
* array. The controller supports M/N output tiling and K tiling, reusing the PE
* accumulators across K tiles before writing C back to memory.
*/

`ifndef _TILED_GEMM_ACCELERATOR
`define _TILED_GEMM_ACCELERATOR

`include "sa_params.sv"
`include "sa_wavefront_feeder.sv"
`include "systolic_array.sv"

module tiled_gemm_accelerator
    #(parameter int I_WORD_SIZE    = MATRIX_WORD_SIZE,
      parameter int O_WORD_SIZE    = 2 * I_WORD_SIZE,
      parameter int NUM_ROWS       = SA_ROWS,
      parameter int NUM_COLS       = SA_COLS,
      parameter int K_TILE         = NUM_COLS,
      parameter int DIM_WIDTH      = 16,
      parameter int ADDR_WIDTH     = 32,
      parameter int MEM_DATA_WIDTH = O_WORD_SIZE)
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
     output logic [63:0]                  o_read_reqs,
     output logic [63:0]                  o_write_reqs,
     output logic [63:0]                  o_tile_count);

    localparam int MEM_BYTES = MEM_DATA_WIDTH / 8;
    localparam int K_W       = (K_TILE <= 1) ? 1 : $clog2(K_TILE + 1);

    typedef enum logic [4:0] {
        S_IDLE,
        S_CLEAR_ARRAY,
        S_CLEAR_TILES,
        S_LOAD_A_REQ,
        S_LOAD_A_WAIT,
        S_LOAD_B_REQ,
        S_LOAD_B_WAIT,
        S_START_FEEDER,
        S_RUN_ARRAY,
        S_NEXT_K,
        S_WRITE_REQ,
        S_WRITE_WAIT,
        S_NEXT_TILE,
        S_DONE,
        S_ERROR
    } state_t;

    state_t state;

    logic [I_WORD_SIZE - 1:0] tile_a [0:NUM_ROWS - 1][0:K_TILE - 1];
    logic [I_WORD_SIZE - 1:0] tile_b [0:K_TILE - 1][0:NUM_COLS - 1];

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
    int unsigned              k_base;
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
        .i_matrixA(tile_a),
        .i_matrixB(tile_b),
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

    function automatic int unsigned current_k_span();
        int unsigned remaining;

        remaining = k_dim - k_base;
        current_k_span = (remaining < K_TILE) ? remaining : K_TILE;
    endfunction : current_k_span

    function automatic bit a_in_bounds();
        a_in_bounds = ((row_base + load_r) < m_dim) &&
                      ((k_base + load_k) < k_dim);
    endfunction : a_in_bounds

    function automatic bit b_in_bounds();
        b_in_bounds = ((k_base + load_k) < k_dim) &&
                      ((col_base + load_c) < n_dim);
    endfunction : b_in_bounds

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

    task automatic clear_tiles();
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int kk = 0; kk < K_TILE; kk++) begin
                tile_a[r][kk] <= '0;
            end
        end

        for (int kk = 0; kk < K_TILE; kk++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                tile_b[kk][c] <= '0;
            end
        end
    endtask : clear_tiles

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

    always_comb begin
        feeder_start      = (state == S_START_FEEDER);
        array_clear       = (state == S_CLEAR_ARRAY);
        feeder_k_dim      = K_W'(current_k_span());
        o_busy            = (state != S_IDLE);
        o_mem_req_valid   = 1'b0;
        o_mem_req_write   = 1'b0;
        o_mem_req_addr    = '0;
        o_mem_req_wdata   = '0;
        o_mem_req_wstrb   = '0;
        o_mem_rsp_ready   = (state == S_LOAD_A_WAIT) ||
                            (state == S_LOAD_B_WAIT) ||
                            (state == S_WRITE_WAIT);

        unique case (state)
            S_LOAD_A_REQ: begin
                if (a_in_bounds()) begin
                    o_mem_req_valid = 1'b1;
                    o_mem_req_addr  = element_addr(base_a,
                                                   row_base + load_r,
                                                   k_base + load_k,
                                                   stride_a);
                end
            end

            S_LOAD_B_REQ: begin
                if (b_in_bounds()) begin
                    o_mem_req_valid = 1'b1;
                    o_mem_req_addr  = element_addr(base_b,
                                                   k_base + load_k,
                                                   col_base + load_c,
                                                   stride_b);
                end
            end

            S_WRITE_REQ: begin
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

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            state                 <= S_IDLE;
            o_done                <= 1'b0;
            o_error               <= 1'b0;
            o_cycles              <= '0;
            o_compute_cycles      <= '0;
            o_memory_stall_cycles <= '0;
            o_read_reqs           <= '0;
            o_write_reqs          <= '0;
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
            k_base                <= 0;
            load_r                <= 0;
            load_k                <= 0;
            load_c                <= 0;
            write_r               <= 0;
            write_c               <= 0;
            clear_tiles();
        end

        else begin
            o_done <= 1'b0;

            if (state != S_IDLE) begin
                o_cycles <= o_cycles + 64'd1;
            end

            if (state == S_RUN_ARRAY) begin
                o_compute_cycles <= o_compute_cycles + 64'd1;
            end

            unique case (state)
                S_IDLE: begin
                    if (i_start) begin
                        o_cycles              <= '0;
                        o_compute_cycles      <= '0;
                        o_memory_stall_cycles <= '0;
                        o_read_reqs           <= '0;
                        o_write_reqs          <= '0;
                        o_tile_count          <= '0;
                        o_error               <= 1'b0;

                        if ((i_m == '0) || (i_n == '0) || (i_k == '0)) begin
                            o_error <= 1'b1;
                            state   <= S_ERROR;
                        end

                        else begin
                            m_dim    <= int'(i_m);
                            n_dim    <= int'(i_n);
                            k_dim    <= int'(i_k);
                            stride_a <= (i_stride_a == '0) ? int'(i_k) : int'(i_stride_a);
                            stride_b <= (i_stride_b == '0) ? int'(i_n) : int'(i_stride_b);
                            stride_c <= (i_stride_c == '0) ? int'(i_n) : int'(i_stride_c);
                            base_a   <= i_base_a;
                            base_b   <= i_base_b;
                            base_c   <= i_base_c;
                            row_base <= 0;
                            col_base <= 0;
                            k_base   <= 0;
                            state    <= S_CLEAR_ARRAY;
                        end
                    end
                end

                S_CLEAR_ARRAY: begin
                    k_base <= 0;
                    state  <= S_CLEAR_TILES;
                end

                S_CLEAR_TILES: begin
                    clear_tiles();
                    load_r  <= 0;
                    load_k  <= 0;
                    load_c  <= 0;
                    write_r <= 0;
                    write_c <= 0;
                    state   <= S_LOAD_A_REQ;
                end

                S_LOAD_A_REQ: begin
                    if (!a_in_bounds()) begin
                        if (load_a_last()) begin
                            load_r <= 0;
                            load_k <= 0;
                            state  <= S_LOAD_B_REQ;
                        end

                        else begin
                            advance_a_load();
                        end
                    end

                    else if (i_mem_req_ready) begin
                        o_read_reqs <= o_read_reqs + 64'd1;
                        state       <= S_LOAD_A_WAIT;
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                S_LOAD_A_WAIT: begin
                    if (i_mem_rsp_valid && !i_mem_rsp_write) begin
                        tile_a[load_r][load_k] <= i_mem_rsp_rdata[I_WORD_SIZE - 1:0];

                        if (load_a_last()) begin
                            load_r <= 0;
                            load_k <= 0;
                            state  <= S_LOAD_B_REQ;
                        end

                        else begin
                            advance_a_load();
                            state <= S_LOAD_A_REQ;
                        end
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                S_LOAD_B_REQ: begin
                    if (!b_in_bounds()) begin
                        if (load_b_last()) begin
                            load_k <= 0;
                            load_c <= 0;
                            state  <= S_START_FEEDER;
                        end

                        else begin
                            advance_b_load();
                        end
                    end

                    else if (i_mem_req_ready) begin
                        o_read_reqs <= o_read_reqs + 64'd1;
                        state       <= S_LOAD_B_WAIT;
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                S_LOAD_B_WAIT: begin
                    if (i_mem_rsp_valid && !i_mem_rsp_write) begin
                        tile_b[load_k][load_c] <= i_mem_rsp_rdata[I_WORD_SIZE - 1:0];

                        if (load_b_last()) begin
                            load_k <= 0;
                            load_c <= 0;
                            state  <= S_START_FEEDER;
                        end

                        else begin
                            advance_b_load();
                            state <= S_LOAD_B_REQ;
                        end
                    end

                    else begin
                        o_memory_stall_cycles <= o_memory_stall_cycles + 64'd1;
                    end
                end

                S_START_FEEDER: begin
                    state <= S_RUN_ARRAY;
                end

                S_RUN_ARRAY: begin
                    if (array_done) begin
                        state <= S_NEXT_K;
                    end
                end

                S_NEXT_K: begin
                    if ((k_base + current_k_span()) >= k_dim) begin
                        write_r <= 0;
                        write_c <= 0;
                        state   <= S_WRITE_REQ;
                    end

                    else begin
                        k_base <= k_base + K_TILE;
                        state  <= S_CLEAR_TILES;
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
                        k_base   <= 0;
                        state    <= S_CLEAR_ARRAY;
                    end

                    else if ((row_base + NUM_ROWS) < m_dim) begin
                        row_base <= row_base + NUM_ROWS;
                        col_base <= 0;
                        k_base   <= 0;
                        state    <= S_CLEAR_ARRAY;
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
