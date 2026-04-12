/*
* sa_params.sv: Defines the microarchitectural parameters of the systolic array.
*
* Author: Albert Luo (albertlu)
*/

`ifndef _SA_PARAMS
`define _SA_PARAMS

parameter int SA_ROWS          = 4;
parameter int SA_COLS          = 4;
parameter int MATRIX_WORD_SIZE = 32;

// Output will be double the input word size due to multiplication.
parameter int SA_WORD_SIZE     = (MATRIX_WORD_SIZE * 2);
`endif // _SA_PARAMS
