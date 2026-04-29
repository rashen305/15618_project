/*
* main_memory_model_test.sv: Self-checking tests for the cycle-counted memory
* model used by the FPGA GEMM benchmark harness.
*/

`timescale 1ns/1ns

`include "main_memory_model.sv"

module main_memory_model_test();
    localparam int ADDR_WIDTH      = 16;
    localparam int DATA_WIDTH      = 32;
    localparam int DATA_BYTES      = DATA_WIDTH / 8;
    localparam int DEPTH_WORDS     = 256;

    logic clk;
    logic rst_l;
    logic i_req_valid;
    logic o_req_ready;
    logic i_req_write;
    logic [ADDR_WIDTH - 1:0] i_req_addr;
    logic [DATA_WIDTH - 1:0] i_req_wdata;
    logic [DATA_BYTES - 1:0] i_req_wstrb;
    logic o_rsp_valid;
    logic i_rsp_ready;
    logic o_rsp_write;
    logic [ADDR_WIDTH - 1:0] o_rsp_addr;
    logic [DATA_WIDTH - 1:0] o_rsp_rdata;
    logic [63:0] o_cycle_count;
    logic [63:0] o_read_count;
    logic [63:0] o_write_count;
    logic [63:0] o_bytes_read;
    logic [63:0] o_bytes_written;
    logic [63:0] o_stall_req_count;

    main_memory_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH_WORDS(DEPTH_WORDS),
        .MAX_OUTSTANDING(4),
        .READ_LATENCY(4),
        .WRITE_LATENCY(2),
        .READ_ACCEPT_GAP(1),
        .WRITE_ACCEPT_GAP(1),
        .MODEL_ROW_BUFFER(1'b0)
    ) mem (
        .*
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_bus();
        i_req_valid <= 1'b0;
        i_req_write <= 1'b0;
        i_req_addr  <= '0;
        i_req_wdata <= '0;
        i_req_wstrb <= '0;
        i_rsp_ready <= 1'b1;
    endtask : clear_bus

    task automatic issue_read(input int unsigned word_addr,
                              output logic [DATA_WIDTH - 1:0] data);
        @(negedge clk);
        i_req_valid <= 1'b1;
        i_req_write <= 1'b0;
        i_req_addr  <= ADDR_WIDTH'(word_addr * DATA_BYTES);
        i_req_wdata <= '0;
        i_req_wstrb <= '0;

        do begin
            @(posedge clk);
        end while (!o_req_ready);

        @(negedge clk);
        i_req_valid <= 1'b0;

        wait (o_rsp_valid && !o_rsp_write);
        data = o_rsp_rdata;
        @(posedge clk);
    endtask : issue_read

    task automatic issue_write(input int unsigned word_addr,
                               input logic [DATA_WIDTH - 1:0] data,
                               input logic [DATA_BYTES - 1:0] wstrb);
        @(negedge clk);
        i_req_valid <= 1'b1;
        i_req_write <= 1'b1;
        i_req_addr  <= ADDR_WIDTH'(word_addr * DATA_BYTES);
        i_req_wdata <= data;
        i_req_wstrb <= wstrb;

        do begin
            @(posedge clk);
        end while (!o_req_ready);

        @(negedge clk);
        i_req_valid <= 1'b0;

        wait (o_rsp_valid && o_rsp_write);
        @(posedge clk);
    endtask : issue_write

    initial begin
        logic [DATA_WIDTH - 1:0] read_data;

        rst_l <= 1'b0;
        clear_bus();
        repeat (3) @(posedge clk);
        rst_l <= 1'b1;
        mem.clear_memory();

        mem.write_word(4, 32'hDEAD_BEEF);
        issue_read(4, read_data);
        assert(read_data == 32'hDEAD_BEEF)
            else $fatal(1, "Expected 0xDEADBEEF, got 0x%08h.", read_data);

        issue_write(8, 32'h0123_4567, 4'b1111);
        issue_read(8, read_data);
        assert(read_data == 32'h0123_4567)
            else $fatal(1, "Expected full-word write to persist, got 0x%08h.", read_data);

        issue_write(8, 32'h0000_AA00, 4'b0010);
        issue_read(8, read_data);
        assert(read_data == 32'h0123_AA67)
            else $fatal(1, "Expected byte-mask write result 0x0123AA67, got 0x%08h.", read_data);

        assert(o_read_count == 3)
            else $fatal(1, "Expected 3 reads, got %0d.", o_read_count);
        assert(o_write_count == 2)
            else $fatal(1, "Expected 2 writes, got %0d.", o_write_count);
        assert(o_bytes_read == 3 * DATA_BYTES)
            else $fatal(1, "Unexpected bytes_read=%0d.", o_bytes_read);
        assert(o_bytes_written == 2 * DATA_BYTES)
            else $fatal(1, "Unexpected bytes_written=%0d.", o_bytes_written);

        $display("\n");
        $display("***************************************************************************");
        $display("                         MEMORY MODEL TESTS PASSED                         ");
        $display("***************************************************************************");
        $display("\n");

        $finish;
    end
endmodule : main_memory_model_test
