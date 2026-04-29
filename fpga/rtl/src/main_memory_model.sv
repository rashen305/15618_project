/*
* main_memory_model.sv: Cycle-counted main-memory model for RTL simulation.
*
* The model exposes a single ready/valid request port and a single ready/valid
* response port. It is intentionally parameterized so benchmark sweeps can vary
* latency, request bandwidth, outstanding depth, row-buffer behavior, and size.
*/

`ifndef _MAIN_MEMORY_MODEL
`define _MAIN_MEMORY_MODEL

module main_memory_model
    #(parameter int ADDR_WIDTH        = 32,
      parameter int DATA_WIDTH        = 32,
      parameter int DEPTH_WORDS       = 1 << 16,
      parameter int MAX_OUTSTANDING   = 16,
      parameter int READ_LATENCY      = 40,
      parameter int WRITE_LATENCY     = 20,
      parameter int READ_ACCEPT_GAP   = 0,
      parameter int WRITE_ACCEPT_GAP  = 0,
      parameter int BANKS             = 4,
      parameter int ROW_WORDS         = 1024,
      parameter int ROW_HIT_LATENCY   = 12,
      parameter int ROW_MISS_PENALTY  = 28,
      parameter bit MODEL_ROW_BUFFER  = 1'b1,
      parameter bit WRITE_RESP_ENABLE = 1'b1)
    (input  logic                         clk,
     input  logic                         rst_l,

     input  logic                         i_req_valid,
     output logic                         o_req_ready,
     input  logic                         i_req_write,
     input  logic [ADDR_WIDTH - 1:0]      i_req_addr,
     input  logic [DATA_WIDTH - 1:0]      i_req_wdata,
     input  logic [(DATA_WIDTH / 8) - 1:0] i_req_wstrb,

     output logic                         o_rsp_valid,
     input  logic                         i_rsp_ready,
     output logic                         o_rsp_write,
     output logic [ADDR_WIDTH - 1:0]      o_rsp_addr,
     output logic [DATA_WIDTH - 1:0]      o_rsp_rdata,

     output logic [63:0]                  o_cycle_count,
     output logic [63:0]                  o_read_count,
     output logic [63:0]                  o_write_count,
     output logic [63:0]                  o_bytes_read,
     output logic [63:0]                  o_bytes_written,
     output logic [63:0]                  o_stall_req_count);

    localparam int DATA_BYTES   = DATA_WIDTH / 8;
    localparam int BYTE_OFF_W   = (DATA_BYTES <= 1) ? 1 : $clog2(DATA_BYTES);

    logic [DATA_WIDTH - 1:0] mem [0:DEPTH_WORDS - 1];

    // Backdoor testbench access is converted into requests that are serviced by
    // the same sequential process that services normal memory writes. This keeps
    // `mem` single-driven and avoids simulator multiple/combinational driver
    // diagnostics when hierarchical tasks are used.
    logic                         backdoor_clear = 1'b0;
    logic                         backdoor_we    = 1'b0;
    int unsigned                  backdoor_word_addr = 0;
    logic [DATA_WIDTH - 1:0]      backdoor_wdata = '0;

    logic                    pipe_valid [0:MAX_OUTSTANDING - 1];
    logic                    pipe_write [0:MAX_OUTSTANDING - 1];
    logic [31:0]             pipe_count [0:MAX_OUTSTANDING - 1];
    logic [ADDR_WIDTH - 1:0] pipe_addr  [0:MAX_OUTSTANDING - 1];
    logic [DATA_WIDTH - 1:0] pipe_wdata [0:MAX_OUTSTANDING - 1];
    logic [DATA_BYTES - 1:0] pipe_wstrb [0:MAX_OUTSTANDING - 1];

    logic                    row_open [0:BANKS - 1];
    int unsigned             open_row [0:BANKS - 1];

    logic [31:0]             req_gap_count;
    integer                  free_idx;
    integer                  mature_idx;

    initial begin
        if ((DATA_WIDTH % 8) != 0) begin
            $fatal(1, "main_memory_model requires DATA_WIDTH to be byte-aligned.");
        end

        if (MAX_OUTSTANDING < 1) begin
            $fatal(1, "main_memory_model requires MAX_OUTSTANDING >= 1.");
        end

        if (BANKS < 1) begin
            $fatal(1, "main_memory_model requires BANKS >= 1.");
        end

        if (ROW_WORDS < 1) begin
            $fatal(1, "main_memory_model requires ROW_WORDS >= 1.");
        end
    end

    function automatic int unsigned word_index(input logic [ADDR_WIDTH - 1:0] addr);
        word_index = int'(addr >> BYTE_OFF_W);
    endfunction : word_index

    function automatic int unsigned bank_index(input int unsigned word);
        bank_index = word % BANKS;
    endfunction : bank_index

    function automatic int unsigned row_index(input int unsigned word);
        row_index = word / (BANKS * ROW_WORDS);
    endfunction : row_index

    function automatic logic [DATA_WIDTH - 1:0] apply_wstrb(
        input logic [DATA_WIDTH - 1:0] old_word,
        input logic [DATA_WIDTH - 1:0] new_word,
        input logic [DATA_BYTES - 1:0] wstrb
    );
        logic [DATA_WIDTH - 1:0] merged;

        merged = old_word;
        for (int b = 0; b < DATA_BYTES; b++) begin
            if (wstrb[b]) begin
                merged[b * 8 +: 8] = new_word[b * 8 +: 8];
            end
        end

        apply_wstrb = merged;
    endfunction : apply_wstrb

    function automatic logic [31:0] nonzero_latency(input int latency);
        nonzero_latency = (latency <= 0) ? 32'd1 : $unsigned(latency);
    endfunction : nonzero_latency

    always_comb begin
        free_idx = -1;
        for (int p = 0; p < MAX_OUTSTANDING; p++) begin
            if (!pipe_valid[p] && (free_idx < 0)) begin
                free_idx = p;
            end
        end

        mature_idx = -1;
        for (int p = 0; p < MAX_OUTSTANDING; p++) begin
            if (pipe_valid[p] && (pipe_count[p] == 32'd0) && (mature_idx < 0)) begin
                mature_idx = p;
            end
        end

        o_req_ready = (free_idx >= 0) && (req_gap_count == 32'd0);
    end

    always_ff @(posedge clk, negedge rst_l) begin
        if (~rst_l) begin
            o_rsp_valid       <= 1'b0;
            o_rsp_write       <= 1'b0;
            o_rsp_addr        <= '0;
            o_rsp_rdata       <= '0;
            o_cycle_count     <= '0;
            o_read_count      <= '0;
            o_write_count     <= '0;
            o_bytes_read      <= '0;
            o_bytes_written   <= '0;
            o_stall_req_count <= '0;
            req_gap_count     <= '0;

            for (int p = 0; p < MAX_OUTSTANDING; p++) begin
                pipe_valid[p] <= 1'b0;
                pipe_write[p] <= 1'b0;
                pipe_count[p] <= '0;
                pipe_addr[p]  <= '0;
                pipe_wdata[p] <= '0;
                pipe_wstrb[p] <= '0;
            end

            for (int b = 0; b < BANKS; b++) begin
                row_open[b] <= 1'b0;
                open_row[b] <= 0;
            end
        end

        else begin
            logic rsp_fire;
            logic accept_fire;

            rsp_fire   = o_rsp_valid & i_rsp_ready;
            accept_fire = i_req_valid & o_req_ready;

            o_cycle_count <= o_cycle_count + 64'd1;

            if (i_req_valid & ~o_req_ready) begin
                o_stall_req_count <= o_stall_req_count + 64'd1;
            end

            if (req_gap_count != 32'd0) begin
                req_gap_count <= req_gap_count - 32'd1;
            end

            for (int p = 0; p < MAX_OUTSTANDING; p++) begin
                if (pipe_valid[p] && (pipe_count[p] != 32'd0)) begin
                    pipe_count[p] <= pipe_count[p] - 32'd1;
                end
            end

            if (backdoor_clear) begin
                for (int i = 0; i < DEPTH_WORDS; i++) begin
                    mem[i] <= '0;
                end
            end

            else if (backdoor_we) begin
                mem[backdoor_word_addr] <= backdoor_wdata;
            end

            if (rsp_fire) begin
                o_rsp_valid <= 1'b0;
            end

            if (((~o_rsp_valid) || rsp_fire) && (mature_idx >= 0)) begin
                int unsigned rsp_word;

                rsp_word    = word_index(pipe_addr[mature_idx]);
                o_rsp_valid <= pipe_write[mature_idx] ? WRITE_RESP_ENABLE : 1'b1;
                o_rsp_write <= pipe_write[mature_idx];
                o_rsp_addr  <= pipe_addr[mature_idx];

                if (rsp_word >= DEPTH_WORDS) begin
                    $fatal(1, "main_memory_model response address 0x%0h is outside memory.", pipe_addr[mature_idx]);
                end

                if (pipe_write[mature_idx]) begin
                    if (!backdoor_clear && !backdoor_we) begin
                        mem[rsp_word] <= apply_wstrb(mem[rsp_word],
                                                     pipe_wdata[mature_idx],
                                                     pipe_wstrb[mature_idx]);
                    end
                    o_rsp_rdata <= '0;
                end

                else begin
                    o_rsp_rdata <= mem[rsp_word];
                end

                pipe_valid[mature_idx] <= 1'b0;
            end

            if (accept_fire) begin
                int unsigned req_word;
                int unsigned req_bank;
                int unsigned req_row;
                logic [31:0] req_latency;

                req_word = word_index(i_req_addr);
                req_bank = bank_index(req_word);
                req_row  = row_index(req_word);

                if (req_word >= DEPTH_WORDS) begin
                    $fatal(1, "main_memory_model request address 0x%0h is outside memory.", i_req_addr);
                end

                if (MODEL_ROW_BUFFER) begin
                    if (row_open[req_bank] && (open_row[req_bank] == req_row)) begin
                        req_latency = nonzero_latency(ROW_HIT_LATENCY);
                    end

                    else begin
                        req_latency = nonzero_latency((i_req_write ? WRITE_LATENCY : READ_LATENCY) +
                                                      ROW_MISS_PENALTY);
                        row_open[req_bank] <= 1'b1;
                        open_row[req_bank] <= req_row;
                    end
                end

                else begin
                    req_latency = nonzero_latency(i_req_write ? WRITE_LATENCY : READ_LATENCY);
                end

                pipe_valid[free_idx] <= 1'b1;
                pipe_write[free_idx] <= i_req_write;
                pipe_count[free_idx] <= req_latency;
                pipe_addr[free_idx]  <= i_req_addr;
                pipe_wdata[free_idx] <= i_req_wdata;
                pipe_wstrb[free_idx] <= i_req_wstrb;

                if (i_req_write) begin
                    o_write_count    <= o_write_count + 64'd1;
                    o_bytes_written  <= o_bytes_written + DATA_BYTES;
                    req_gap_count    <= WRITE_ACCEPT_GAP;
                end

                else begin
                    o_read_count     <= o_read_count + 64'd1;
                    o_bytes_read     <= o_bytes_read + DATA_BYTES;
                    req_gap_count    <= READ_ACCEPT_GAP;
                end
            end
        end
    end

    task automatic clear_memory();
        backdoor_clear = 1'b1;
        @(posedge clk);
        backdoor_clear = 1'b0;
    endtask : clear_memory

    task automatic write_word(input int unsigned word_addr,
                              input logic [DATA_WIDTH - 1:0] data);
        if (word_addr >= DEPTH_WORDS) begin
            $fatal(1, "main_memory_model.write_word index %0d is outside memory.", word_addr);
        end

        backdoor_word_addr = word_addr;
        backdoor_wdata     = data;
        backdoor_we        = 1'b1;
        @(posedge clk);
        backdoor_we        = 1'b0;
    endtask : write_word

    function automatic logic [DATA_WIDTH - 1:0] read_word(input int unsigned word_addr);
        if (word_addr >= DEPTH_WORDS) begin
            $fatal(1, "main_memory_model.read_word index %0d is outside memory.", word_addr);
        end

        read_word = mem[word_addr];
    endfunction : read_word

endmodule : main_memory_model
`endif // _MAIN_MEMORY_MODEL
