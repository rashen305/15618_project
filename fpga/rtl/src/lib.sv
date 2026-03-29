/*
* lib.sv: Contains combinational and sequential components for modularity.
*
* Author: Albert Luo (albertlu)
*/

`ifndef _LIB_SV
`define _LIB_SV

`include "sa_params.sv"

/*
* Register with a **synchronous** reset and clear.
*/
module register
    #(parameter int WIDTH     = MATRIX_WORD_SIZE)
    (input  logic               clk,
     input  logic               rst_l,
     input  logic               clear,
     input  logic               en,
     input  logic [WIDTH - 1:0] regIn,
     output logic [WIDTH - 1:0] regOut);

    always_ff @(posedge clk) begin
        if (~rst_l | clear) begin
            regOut <= '0;
        end

        else if (en) begin
            regOut <= regIn;
        end
    end
endmodule : register

/*
* Traditionaly 2-to-1 multiplexer.
*/
module mux2to1
    #(parameter int WIDTH = SA_WORD_SIZE)
    (input  logic [WIDTH - 1:0] muxIn0,
     input  logic [WIDTH - 1:0] muxIn1,
     input  logic               sel,
     output logic [WIDTH - 1:0] muxOut);

    assign muxOut = (sel) ? muxIn1 : muxIn0;
endmodule : mux2to1

/*
* Full adder without carry-in/out (unnecessary for PEs).
*/
module adder
    #(parameter int WIDTH = SA_WORD_SIZE)
    (input  logic [WIDTH - 1:0] adderIn1,
     input  logic [WIDTH - 1:0] adderIn2,
     output logic [WIDTH - 1:0] adderOut);

    assign adderOut = (adderIn1 + adderIn2);
endmodule : adder

/*
* Combinational multiplier (for now).
*/
module multiplier
    #(parameter int I_WIDTH = MATRIX_WORD_SIZE,
      parameter int O_WIDTH = (2 * I_WIDTH))
    (input  logic [I_WIDTH - 1:0] multIn1,
     input  logic [I_WIDTH - 1:0] multIn2,
     output logic [O_WIDTH - 1:0] multOut);

    // TODO: Decide if we want to use our own multiplier or DSP slices.
    assign multOut = (multIn1 * multIn2);
endmodule : multiplier
`endif // _LIB_SV
