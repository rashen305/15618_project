/*
* systolic_gemm_engine.sv: Multi-shape GEMM engine. This wrapper instantiates
* several tiled GEMM accelerators with different systolic-array dimensions and
* dispatches one selected slot onto a shared memory port.
*/

`ifndef _SYSTOLIC_GEMM_ENGINE
`define _SYSTOLIC_GEMM_ENGINE

`include "tiled_gemm_accelerator.sv"

module systolic_gemm_engine
    #(parameter int I_WORD_SIZE          = MATRIX_WORD_SIZE,
      parameter int O_WORD_SIZE          = 2 * I_WORD_SIZE,
      parameter int DIM_WIDTH            = 16,
      parameter int ADDR_WIDTH           = 32,
      parameter int MEM_DATA_WIDTH       = O_WORD_SIZE,
      parameter bit ENABLE_DOUBLE_BUFFER = 1'b1,
      parameter int SLOT0_ROWS           = 2,
      parameter int SLOT0_COLS           = 2,
      parameter int SLOT0_K_TILE         = 4,
      parameter int SLOT1_ROWS           = 4,
      parameter int SLOT1_COLS           = 4,
      parameter int SLOT1_K_TILE         = 8,
      parameter int SLOT2_ROWS           = 8,
      parameter int SLOT2_COLS           = 4,
      parameter int SLOT2_K_TILE         = 8)
    (input  logic                         clk,
     input  logic                         rst_l,

     input  logic                         i_start,
     input  logic [1:0]                   i_array_select,
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
     output logic [1:0]                   o_active_array,
     output logic [63:0]                  o_cycles,
     output logic [63:0]                  o_compute_cycles,
     output logic [63:0]                  o_memory_stall_cycles,
     output logic [63:0]                  o_prefetch_cycles,
     output logic [63:0]                  o_compute_wait_cycles,
     output logic [63:0]                  o_read_reqs,
     output logic [63:0]                  o_write_reqs,
     output logic [63:0]                  o_loaded_tile_count,
     output logic [63:0]                  o_tile_count);

    logic [1:0] active_array;
    logic       invalid_select_pending;

    logic [2:0] lane_start;
    logic [2:0] lane_req_valid;
    logic [2:0] lane_req_ready;
    logic [2:0] lane_req_write;
    logic [ADDR_WIDTH - 1:0] lane_req_addr [0:2];
    logic [MEM_DATA_WIDTH - 1:0] lane_req_wdata [0:2];
    logic [(MEM_DATA_WIDTH / 8) - 1:0] lane_req_wstrb [0:2];

    logic [2:0] lane_rsp_valid;
    logic [2:0] lane_rsp_ready;
    logic [2:0] lane_busy;
    logic [2:0] lane_done;
    logic [2:0] lane_error;

    logic [63:0] lane_cycles [0:2];
    logic [63:0] lane_compute_cycles [0:2];
    logic [63:0] lane_memory_stall_cycles [0:2];
    logic [63:0] lane_prefetch_cycles [0:2];
    logic [63:0] lane_compute_wait_cycles [0:2];
    logic [63:0] lane_read_reqs [0:2];
    logic [63:0] lane_write_reqs [0:2];
    logic [63:0] lane_loaded_tile_count [0:2];
    logic [63:0] lane_tile_count [0:2];

    assign o_active_array = active_array;
    assign o_busy         = lane_busy[active_array];
    assign o_done         = lane_done[active_array] | invalid_select_pending;
    assign o_error        = lane_error[active_array] | invalid_select_pending;

    assign o_cycles              = lane_cycles[active_array];
    assign o_compute_cycles      = lane_compute_cycles[active_array];
    assign o_memory_stall_cycles = lane_memory_stall_cycles[active_array];
    assign o_prefetch_cycles     = lane_prefetch_cycles[active_array];
    assign o_compute_wait_cycles = lane_compute_wait_cycles[active_array];
    assign o_read_reqs           = lane_read_reqs[active_array];
    assign o_write_reqs          = lane_write_reqs[active_array];
    assign o_loaded_tile_count   = lane_loaded_tile_count[active_array];
    assign o_tile_count          = lane_tile_count[active_array];

    always_comb begin
        lane_start = '0;

        if (i_start && (i_array_select < 2'd3) && !o_busy) begin
            lane_start[i_array_select] = 1'b1;
        end

        lane_req_ready = '0;
        lane_rsp_valid = '0;

        o_mem_req_valid = lane_req_valid[active_array];
        o_mem_req_write = lane_req_write[active_array];
        o_mem_req_addr  = lane_req_addr[active_array];
        o_mem_req_wdata = lane_req_wdata[active_array];
        o_mem_req_wstrb = lane_req_wstrb[active_array];
        o_mem_rsp_ready = lane_rsp_ready[active_array];

        lane_req_ready[active_array] = i_mem_req_ready;
        lane_rsp_valid[active_array] = i_mem_rsp_valid;
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            active_array           <= 2'd0;
            invalid_select_pending <= 1'b0;
        end

        else begin
            invalid_select_pending <= 1'b0;

            if (i_start && !o_busy) begin
                if (i_array_select < 2'd3) begin
                    active_array <= i_array_select;
                end

                else begin
                    invalid_select_pending <= 1'b1;
                end
            end
        end
    end

    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(SLOT0_ROWS),
        .NUM_COLS(SLOT0_COLS),
        .K_TILE(SLOT0_K_TILE),
        .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .ENABLE_DOUBLE_BUFFER(ENABLE_DOUBLE_BUFFER)
    ) slot0 (
        .clk,
        .rst_l,
        .i_start(lane_start[0]),
        .i_m,
        .i_n,
        .i_k,
        .i_base_a,
        .i_base_b,
        .i_base_c,
        .i_stride_a,
        .i_stride_b,
        .i_stride_c,
        .o_mem_req_valid(lane_req_valid[0]),
        .i_mem_req_ready(lane_req_ready[0]),
        .o_mem_req_write(lane_req_write[0]),
        .o_mem_req_addr(lane_req_addr[0]),
        .o_mem_req_wdata(lane_req_wdata[0]),
        .o_mem_req_wstrb(lane_req_wstrb[0]),
        .i_mem_rsp_valid(lane_rsp_valid[0]),
        .o_mem_rsp_ready(lane_rsp_ready[0]),
        .i_mem_rsp_write,
        .i_mem_rsp_addr,
        .i_mem_rsp_rdata,
        .o_busy(lane_busy[0]),
        .o_done(lane_done[0]),
        .o_error(lane_error[0]),
        .o_cycles(lane_cycles[0]),
        .o_compute_cycles(lane_compute_cycles[0]),
        .o_memory_stall_cycles(lane_memory_stall_cycles[0]),
        .o_prefetch_cycles(lane_prefetch_cycles[0]),
        .o_compute_wait_cycles(lane_compute_wait_cycles[0]),
        .o_read_reqs(lane_read_reqs[0]),
        .o_write_reqs(lane_write_reqs[0]),
        .o_loaded_tile_count(lane_loaded_tile_count[0]),
        .o_tile_count(lane_tile_count[0])
    );

    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(SLOT1_ROWS),
        .NUM_COLS(SLOT1_COLS),
        .K_TILE(SLOT1_K_TILE),
        .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .ENABLE_DOUBLE_BUFFER(ENABLE_DOUBLE_BUFFER)
    ) slot1 (
        .clk,
        .rst_l,
        .i_start(lane_start[1]),
        .i_m,
        .i_n,
        .i_k,
        .i_base_a,
        .i_base_b,
        .i_base_c,
        .i_stride_a,
        .i_stride_b,
        .i_stride_c,
        .o_mem_req_valid(lane_req_valid[1]),
        .i_mem_req_ready(lane_req_ready[1]),
        .o_mem_req_write(lane_req_write[1]),
        .o_mem_req_addr(lane_req_addr[1]),
        .o_mem_req_wdata(lane_req_wdata[1]),
        .o_mem_req_wstrb(lane_req_wstrb[1]),
        .i_mem_rsp_valid(lane_rsp_valid[1]),
        .o_mem_rsp_ready(lane_rsp_ready[1]),
        .i_mem_rsp_write,
        .i_mem_rsp_addr,
        .i_mem_rsp_rdata,
        .o_busy(lane_busy[1]),
        .o_done(lane_done[1]),
        .o_error(lane_error[1]),
        .o_cycles(lane_cycles[1]),
        .o_compute_cycles(lane_compute_cycles[1]),
        .o_memory_stall_cycles(lane_memory_stall_cycles[1]),
        .o_prefetch_cycles(lane_prefetch_cycles[1]),
        .o_compute_wait_cycles(lane_compute_wait_cycles[1]),
        .o_read_reqs(lane_read_reqs[1]),
        .o_write_reqs(lane_write_reqs[1]),
        .o_loaded_tile_count(lane_loaded_tile_count[1]),
        .o_tile_count(lane_tile_count[1])
    );

    tiled_gemm_accelerator #(
        .I_WORD_SIZE(I_WORD_SIZE),
        .O_WORD_SIZE(O_WORD_SIZE),
        .NUM_ROWS(SLOT2_ROWS),
        .NUM_COLS(SLOT2_COLS),
        .K_TILE(SLOT2_K_TILE),
        .DIM_WIDTH(DIM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH),
        .ENABLE_DOUBLE_BUFFER(ENABLE_DOUBLE_BUFFER)
    ) slot2 (
        .clk,
        .rst_l,
        .i_start(lane_start[2]),
        .i_m,
        .i_n,
        .i_k,
        .i_base_a,
        .i_base_b,
        .i_base_c,
        .i_stride_a,
        .i_stride_b,
        .i_stride_c,
        .o_mem_req_valid(lane_req_valid[2]),
        .i_mem_req_ready(lane_req_ready[2]),
        .o_mem_req_write(lane_req_write[2]),
        .o_mem_req_addr(lane_req_addr[2]),
        .o_mem_req_wdata(lane_req_wdata[2]),
        .o_mem_req_wstrb(lane_req_wstrb[2]),
        .i_mem_rsp_valid(lane_rsp_valid[2]),
        .o_mem_rsp_ready(lane_rsp_ready[2]),
        .i_mem_rsp_write,
        .i_mem_rsp_addr,
        .i_mem_rsp_rdata,
        .o_busy(lane_busy[2]),
        .o_done(lane_done[2]),
        .o_error(lane_error[2]),
        .o_cycles(lane_cycles[2]),
        .o_compute_cycles(lane_compute_cycles[2]),
        .o_memory_stall_cycles(lane_memory_stall_cycles[2]),
        .o_prefetch_cycles(lane_prefetch_cycles[2]),
        .o_compute_wait_cycles(lane_compute_wait_cycles[2]),
        .o_read_reqs(lane_read_reqs[2]),
        .o_write_reqs(lane_write_reqs[2]),
        .o_loaded_tile_count(lane_loaded_tile_count[2]),
        .o_tile_count(lane_tile_count[2])
    );

endmodule : systolic_gemm_engine
`endif // _SYSTOLIC_GEMM_ENGINE
