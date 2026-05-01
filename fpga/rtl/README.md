# RTL — Tiled Systolic GEMM Accelerator

SystemVerilog RTL for the tiled systolic-array GEMM engine and supporting testbenches.
Simulated with VCS (`-sverilog`). All modules are parameterized and synthesizable.

---

## Source files

### Architecture

| File | Description |
|---|---|
| `sa_params.sv` | Package-level constants: `MATRIX_WORD_SIZE`, `SA_ROWS`, `SA_COLS`, `SA_DATAFLOW_OS/WS/NS` |
| `lib.sv` | Parameterized `register` and `multiplier` primitives used across the design |
| `sa_processing_elem.sv` | Processing element. One MAC per cycle. Accumulator register cleared on `i_acc_clear`. Stationary-operand registers (`stationaryWeight`, `stationaryInput`) activated by dataflow mode at elaboration time |
| `sa_wavefront_feeder.sv` | Diagonal injection schedule. Asserts `o_rowsValid[i]` / `o_colsValid[j]` when `k = cycle - i` or `k = cycle - j` is in range. Total active cycles = `K_DIM + NUM_ROWS + NUM_COLS - 2`. Pulses `o_done` on the last cycle |
| `sa_double_buffered_feeder.sv` | Ping-pong variant. Accepts `i_next_valid` to pre-load the alternate bank while the current tile is feeding. Fires `o_done` then immediately rolls to the next bank if `next_pending` is set — zero idle cycles between tiles |
| `systolic_array.sv` | R×C PE mesh. Instantiates `sa_processing_elem` in a generate loop. `done_shift` is a `(R-1)+(C-1)`-bit shift register that delays `i_feederDone` to produce `o_compDone` exactly when the last PE has committed its final product |
| `tiled_gemm_accelerator.sv` | Top-level tile controller. 11-state FSM (`S_IDLE` → `S_TILE_BEGIN` → `S_WAIT_FIRST_LOAD` → `S_START_COMPUTE` → `S_RUN` → `S_WAIT_BUFFER` → `S_WRITE_REQ` → `S_WRITE_WAIT` → `S_NEXT_TILE` → `S_DONE` / `S_ERROR`). Concurrent load FSM (`L_IDLE` → `L_A_REQ` → `L_A_WAIT` → `L_B_REQ` → `L_B_WAIT`). Ping-pong tile buffers `tile_a[2][R][KT]`, `tile_b[2][KT][C]`. Performance counters: `o_cycles`, `o_compute_cycles`, `o_memory_stall_cycles`, `o_prefetch_cycles`, `o_compute_wait_cycles`, `o_read_reqs`, `o_write_reqs`, `o_loaded_tile_count`, `o_tile_count` |
| `systolic_gemm_engine.sv` | Multi-slot wrapper. Instantiates three `tiled_gemm_accelerator` slots with independent dimensions. Routes the selected slot (`i_array_select`) onto the shared memory port. Raises `o_error` on invalid selection |
| `main_memory_model.sv` | Cycle-accurate memory model with configurable `READ_LATENCY`, `WRITE_LATENCY`, `MAX_OUTSTANDING` slots, `READ/WRITE_ACCEPT_GAP`, `BANKS`, `ROW_WORDS`, row-hit/miss penalties, and optional row-buffer behaviour. Exposes stat counters and a backdoor task API (`clear_memory`, `write_word`, `read_word`) for testbenches |

### Testbenches

| File | Tests |
|---|---|
| `systolic_array_test.sv` | Functional correctness of the R×C array on hand-computed 4×4 × 4×4 and 8×8 cases |
| `feeder_test.sv` | Wavefront timing: verifies that each PE receives the correct operand pair at the correct cycle |
| `main_memory_model_test.sv` | Memory model pipeline: checks ready/valid handshake, max-outstanding backpressure, and row-buffer hit/miss accounting |
| `tiled_gemm_accelerator_test.sv` | End-to-end tiled GEMM across multiple M/N/K configurations; checks C output element-by-element |
| `systolic_gemm_engine_test.sv` | Multi-slot engine test. Runs a benchmark GEMM and emits `engine_bench_header` / `engine_bench` CSV lines parsed by `sweep_hw.py` |
| `sa_benchmark_test.sv` | Parameterizable benchmark entry point used by the Makefile `bench-sa` target |
| `sa_stress_test.sv` | Randomised input stress test with self-checking |

---

## Building and running

```bash
# All functional tests
make regress

# Single benchmark (emits CSV row to stdout)
make bench-engine \
    ROWS=16 COLS=16 KTILE=32 \
    M=512 N=512 K=512 \
    DATAFLOW_MODE=1 \
    DBUF=1 \
    READ_LAT=4 WRITE_LAT=1 \
    CLOCK_MHZ=200

# Clean build artifacts
make clean
```

The `DATAFLOW_MODE` parameter maps to: `0` = output-stationary, `1` = weight-stationary, `2` = input-stationary.

---

## Memory model profiles

These match the profiles in `../software/estimate_perf.py` exactly.

| Profile | Read lat | Write lat | Max outstanding | Row buffer |
|---|---|---|---|---|
| L1-like | 4 | 1 | 64 | off |
| L2-like | 12 | 4 | 32 | off |
| LLC-like | 36 | 12 | 16 | off |
| DRAM-like | 120 | 60 | 8 | on (hit=12, miss=60) |
