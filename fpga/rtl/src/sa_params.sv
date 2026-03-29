/*
* sa_params.sv: Defines the microarchitectural parameters of the systolic array.
*
* Author: Albert Luo (albertlu)
*/

`ifndef _SA_PARAMS
`define _SA_PARAMS

// Defines the architecture of the systolic array.
typedef enum logic [1:0] {
    SA_STATIONARY,
    SA_TPU_STATIONARY,
    SA_MEISSA
} sa_arch_t;

parameter int SA_ROWS          = 4;
parameter int SA_COLS          = 4;
parameter int MATRIX_WORD_SIZE = 16;

// Output will be double the input word size due to multiplication.
parameter int SA_WORD_SIZE     = (MATRIX_WORD_SIZE * 2);

parameter sa_arch_t SA_TYPE    = SA_STATIONARY;
`endif // _SA_PARAMS
