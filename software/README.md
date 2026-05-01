# Software — CPU/GPU Baselines and Performance Tools

This directory contains the CPU and GPU baseline implementations and the
Python-based performance analysis toolchain.

---

## CPU baseline (`cpu/`)

C++ GEMM with OpenMP parallelism and cache-blocked tiling.

- `ref`: straightforward dot-product triple loop (correctness reference)
- `cpu_naive`: improved memory access order, no threading
- `cpu_omp`: OpenMP outer loop + configurable tile size; tile-64 is optimal on i7-9700

```bash
# Build
make cpu

# Benchmark (compute-only, no allocation timing)
./gemm_cpu --size 1024 --tile 64 --threads 8 --compute-only
```

---

## GPU baseline (`gpu/`)

CUDA GEMM kernels.

- `gpu_naive`: one thread per output element, global memory only
- `gpu_tiled`: shared-memory tiled kernel; tile-16 and tile-32 sweep

```bash
# Build
nvcc -O3 -arch=sm_75 gemm_gpu.cu -o gemm_gpu

# Benchmark
./gemm_gpu --size 1024 --tile 16
./gemm_gpu --size 1024 --tile 32
```

---

## Performance tools

### `estimate_perf.py` — analytical accelerator estimator

Mirrors the RTL FSM and memory model to produce cycle-approximate performance
estimates without running VCS. Runs a 600-point sweep in under 0.2 seconds.

**Compute cycles** are exact (wavefront formula `K + R + C - 2` per K-tile).
**Memory cycles** are a closed-form lower bound using request count, latency,
max-outstanding pipelining, accept gaps, and row-buffer locality.

```bash
# Basic sweep
python3 estimate_perf.py \
    --arrays 8x8x16,16x16x32,32x32x64,64x64x128 \
    --shapes 128x128x128,512x512x512,1024x1024x1024 \
    --dataflows os,ws,is \
    --mem l1,l2,llc,dram \
    --double-buffer 0,1 \
    --clock-mhz 200 \
    --out sweep.csv

# Append a follow-up run without overwriting the header
python3 estimate_perf.py --arrays 128x128x256 --shapes 2048x2048x2048 \
    --dataflows ws --mem dram --clock-mhz 200 \
    --out sweep.csv --append
```

**Important:** default clock is **200 MHz** to match the paper figures.
Dataflow names: `os` (output-stationary), `ws` (weight-stationary), `is` (input-stationary).
Memory profiles: `l1`, `l2`, `llc`, `dram` — parameters match `main_memory_model.sv` exactly.

---

### `sweep_hw.py` — VCS simulation driver

Invokes `make bench-engine` for each parameter combination, parses the
`engine_bench` CSV rows emitted by `systolic_gemm_engine_test.sv`, and appends
results to a CSV. Use this when you want cycle-exact simulation results rather
than analytical estimates.

```bash
# Run a hardware sweep (slow — each point runs VCS)
python3 sweep_hw.py \
    --arrays 8x8x16,16x16x32 \
    --shapes 64x64x64,256x256x256 \
    --dataflows os,ws,is \
    --mem l1,dram \
    --clock-mhz 200 \
    --out hw_results.csv
```

---

### `poster_plots.py` — full poster figure suite

Generates all 9 individual figures plus a 4-up compound panel from the
estimator CSV. Figures match the final report exactly when run at 200 MHz with
the L1 default memory model.

```bash
python3 poster_plots.py \
    --estimator estimate_perf.py \
    --plot-dir figures/ \
    --clock-mhz 200 \
    --default-mem l1
```

Figures produced:

| File | Content |
|---|---|
| `fig01_throughput_vs_square_size.png` | Effective GFLOP/s vs N for 5 array sizes |
| `fig02_throughput_vs_rectangular_shape.png` | 8 representative DL workload shapes |
| `fig03_dataflow_comparison.png` | OS vs WS vs IS for fixed 32×32 array |
| `fig04_double_buffer_impact.png` | DBUF=0 vs DBUF=1 with % uplift annotations |
| `fig05_memory_hierarchy_sensitivity.png` | L1/L2/LLC/DRAM throughput for fixed array |
| `fig06_roofline.png` | Arithmetic intensity vs achieved throughput, with compute and BW roofs |
| `fig07_pe_utilization_vs_size.png` | Fill/drain efficiency vs matrix size |
| `fig08_cycle_breakdown.png` | Stacked compute + prefetch vs memory stall fractions |
| `fig09_array_scaling.png` | Peak vs achieved throughput as PE count grows |
| `poster_panel_compound.png` | 4-up summary panel |

---

### `plot_estimates.py` — lightweight per-axis plotter

Auto-detects which dimensions vary in a CSV and renders only the relevant plots.
Compatible with both `estimate_perf.py` and `sweep_hw.py` output.

```bash
python3 plot_estimates.py \
    --csv sweep.csv \
    --plot-dir plots/ \
    --target-gops 1000
```

---

## CSV schema

All tools share the same column schema (subset shown):

| Column | Description |
|---|---|
| `array` | e.g. `16x16x32` (ROWSxCOLSxKTILE) |
| `shape` | e.g. `1024x1024x1024` (MxNxK) |
| `dataflow` | `OS`, `WS`, or `IS` |
| `mem_cfg` | Memory profile label + raw parameters |
| `double_buffer` | `0` or `1` |
| `clock_mhz` | Simulated frequency |
| `cycles` | Total modeled cycles |
| `compute_cycles` | Cycles in S_RUN state |
| `memory_stall_cycles` | Cycles stalled waiting for memory |
| `prefetch_cycles` | Cycles where prefetch overlapped compute |
| `effective_gops` | `2MNK / cycles / clock_mhz * 1000` |
| `compute_gops` | `2MNK / compute_cycles / clock_mhz * 1000` |
| `peak_gops` | `2 * R * C * clock_mhz / 1000` |
| `compute_pe_util` | `macs / (R * C * compute_cycles)` |
| `arithmetic_intensity` | `ops / bytes_moved` |
