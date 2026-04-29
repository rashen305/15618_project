/*
* sa_params.sv: Default architectural parameters for the systolic array RTL.
* Most modules override these through parameters; these values are just sane
* defaults for direct instantiation and simple tests.
*/

`ifndef _SA_PARAMS
`define _SA_PARAMS

parameter int SA_ROWS          = 4;
parameter int SA_COLS          = 4;
parameter int MATRIX_WORD_SIZE = 32;
parameter int SA_DATAFLOW_OS   = 0;
parameter int SA_DATAFLOW_WS   = 1;
parameter int SA_DATAFLOW_NS   = 2;
parameter int SA_WORD_SIZE     = 2 * MATRIX_WORD_SIZE;

`endif // _SA_PARAMS
