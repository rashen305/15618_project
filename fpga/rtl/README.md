# FPGA RTL GEMM Accelerator

This directory contains the SystemVerilog model for the FPGA side of the GEMM
project. The current focus is simulation-quality architectural exploration:
cycle-counted main memory, tiled output-stationary systolic arrays, K tiling,
double buffering, and CSV-producing benchmark sweeps.

## Main Modules

- `src/sa_processing_elem.sv`: one output-stationary PE with local accumulator.
- `src/systolic_array.sv`: parameterized 2D PE mesh.
- `src/sa_wavefront_feeder.sv`: skewed `A[i][k]` / `B[k][j]` wavefront feeder.
- `src/main_memory_model.sv`: ready/valid main-memory model with configurable
  latency, request gaps, bank/row-buffer behavior, and byte masks.
- `src/tiled_gemm_accelerator.sv`: memory-backed tiled GEMM controller with
  optional ping-pong tile buffers. With double buffering enabled, it prefetches
  the next K tile while the current tile streams through the array.
- `src/systolic_gemm_engine.sv`: selectable multi-shape engine with three
  systolic-array slots. This lets a single top-level model compare different
  array dimensions against the same memory interface.

## Tests

Run from `fpga/rtl` on a machine with VCS:

```bash
make regress
```

Individual tests follow the `test-<name>` pattern:

```bash
make test-main_memory_model
make test-tiled_gemm_accelerator
make test-systolic_gemm_engine
```

## Single Benchmark

`sa_benchmark_test.sv` prints one CSV header row and one CSV data row:

```bash
make bench-sa ROWS=4 COLS=4 KTILE=8 M=32 N=32 K=32 \
  READ_LAT=40 WRITE_LAT=20 READ_GAP=0 WRITE_GAP=0 DBUF=1 CLOCK_MHZ=100
```

The multi-shape engine benchmark prints one CSV row per slot:

```bash
make bench-engine
```

Important reported fields:

- `cycles`: total accelerator cycles.
- `compute_cycles`: cycles spent with the array running.
- `prefetch_cycles`: cycles where memory prefetch overlapped array execution.
- `compute_wait_cycles`: cycles waiting for the next K buffer.
- `pe_util`: `M*N*K / (ROWS*COLS*compute_cycles)`.
- `arithmetic_intensity`: modeled operations per byte moved through memory.
- `projected_gflops`: `ops_per_cycle * CLOCK_MHZ / 1000`.

## Sweep Script

The hardware sweep script repeatedly invokes `make bench-sa` and writes a CSV:

```bash
./scripts/sweep_hw.py \
  --arrays 2x2x4,4x4x8,8x4x8 \
  --shapes 8x8x8,16x16x16,32x32x32 \
  --mem 20:10,40:20,80:40:1:1 \
  --double-buffer 1,0 \
  --repeats 3 \
  --out build/fpga_sweep.csv
```

The `--mem` argument is `read_latency:write_latency` or
`read_latency:write_latency:read_accept_gap:write_accept_gap`.

The intent is to support the final report methodology from the proposal:
compare array shapes, quantify fill/drain and memory stalls, and produce
roofline inputs from measured operations per cycle and modeled memory traffic.
