# Accelerating GEMM Using a Simulated Systolic Array-Based ASIC
### A Cross-Platform Performance Analysis

**Albert Luo (albertlu), Raymond Shen (rsshen)**  
15-418/618 Final Project — Spring 2026

📄 [Final Report](15418-final-report.pdf) · 📄 [Milestone Report](15_418_Milestone_Report.pdf) · 📄 [Proposal](15_418_Project_Proposal.pdf)

---

## Summary

We design and evaluate a parameterized, tiled systolic-array GEMM accelerator written in
SystemVerilog RTL, and compare it against optimized CPU (OpenMP) and GPU (CUDA) baselines.
The original goal was an FPGA deployment on an AMD Artix-7; the final evaluation is better
framed as an **ASIC-style microarchitectural design-space study**: the RTL defines and
validates the hardware, while a cycle-approximate Python performance model (`estimate_perf.py`)
sweeps large configurations that would be prohibitively slow to simulate cycle-by-cycle in VCS.

---

## Hardware Design (`fpga/rtl/`)

The RTL implements a fully pipelined, tiled GEMM engine with three selectable
systolic-array configurations under one shared memory interface.

### Key modules

| Module | Role |
|---|---|
| `sa_params.sv` | Global parameters: word sizes, array defaults, dataflow mode constants |
| `sa_processing_elem.sv` | Single PE: MAC unit with accumulator, stationary-operand registers, valid gating. Supports OS/WS/IS dataflows |
| `sa_wavefront_feeder.sv` | Injects A and B tiles with cycle-skewed wavefront timing: `A[i][k]` at `t = i+k`, `B[k][j]` at `t = j+k` |
| `sa_double_buffered_feeder.sv` | Ping-pong variant of the feeder enabling zero-bubble tile-to-tile transitions |
| `systolic_array.sv` | R×C mesh of PEs with a drain shift register of depth `(R-1)+(C-1)` to signal completion |
| `tiled_gemm_accelerator.sv` | 11-state FSM controller: handles M/N/K tiling, ping-pong buffering, memory req/rsp, and writeback. Exposes cycle/stall/prefetch performance counters |
| `systolic_gemm_engine.sv` | Top-level wrapper instantiating three selectable accelerator slots under one memory port |
| `main_memory_model.sv` | Cycle-accurate memory model: parameterized read/write latency, max-outstanding pipelining, accept gaps, row-buffer hit/miss behaviour |
| `lib.sv` | Shared register and multiplier primitives |

### Dataflow modes

| Mode | What stays put | Loop order | Memory saving |
|---|---|---|---|
| OS (0) | C partial sums in PE accumulators | m outer, n inner | None — both A and B reload each tile |
| WS (1) | B (weights) in PE stationary registers | n outer, m inner | B reloaded once per n-tile across all m-tiles |
| IS (2) | A (inputs/activations) in PE stationary registers | m outer, n inner | A reloaded once per m-tile across all n-tiles |

### Running simulations

```bash
cd fpga/rtl
# Functional regression
make regress

# Single benchmark point
make bench-engine ROWS=16 COLS=16 KTILE=32 M=256 N=256 K=256 DATAFLOW_MODE=1 DBUF=1

# Full parameter sweep (runs VCS for each point — slow for large configs)
python3 ../software/sweep_hw.py --rtl-dir .
```

---

## Software (`software/`)

### CPU baseline
C++ with OpenMP and cache-blocked tiling. Sweep over tile sizes shows tile-64 optimal
on the i7-9700 (≈73.6 GFLOP/s at N=1024 compute-only).

### GPU baseline
CUDA with a naive global-memory kernel and a shared-memory tiled kernel.
Tiled kernel (tile-16) reaches ≈1082 GFLOP/s at N=1024 compute-only on RTX 2080.

### Performance tools

| Script | Purpose |
|---|---|
| `estimate_perf.py` | Cycle-approximate analytical estimator. Mirrors the RTL FSM and memory model exactly for compute cycles; uses a closed-form bandwidth/latency model for memory. Runs 600 sweep points in < 0.2 s. Default clock: **200 MHz** |
| `sweep_hw.py` | Drives VCS simulation for each sweep point, parses `engine_bench` CSV output, appends results, generates plots |
| `poster_plots.py` | Renders the full 9-figure + compound-panel poster suite from the estimator CSV. Default clock: **200 MHz** |
| `plot_estimates.py` | Lighter per-axis plotter; auto-detects which parameters vary |

### Quick start — analytical sweep

```bash
cd software

# Square matrix sweep, 3 dataflows, 4 memory tiers, DBUF on/off
python3 estimate_perf.py \
    --arrays 8x8x16,16x16x32,32x32x64 \
    --shapes 256x256x256,1024x1024x1024 \
    --dataflows os,ws,is \
    --mem l1,l2,llc,dram \
    --double-buffer 0,1 \
    --clock-mhz 200 \
    --out results.csv

# Generate all poster figures
python3 poster_plots.py --plot-dir figures/ --clock-mhz 200
```

---

## Key Results

| Finding | Detail |
|---|---|
| **Compute fabric scales well** | 128×128 array → ~6.5 TFLOP/s-equivalent compute-only at 200 MHz |
| **Memory is the bottleneck** | End-to-end effective throughput is 1–21% of peak; the gap is entirely memory-system limited |
| **Dataflow matters** | WS and IS each nearly double throughput vs. OS by eliminating one operand reload per inner tile |
| **Double buffering helps most for small arrays** | +20% for 8×8, +5% for 32×32 — larger arrays are bandwidth-limited, not latency-limited |
| **Fill/drain overhead** | PE utilization plateaus at ~50% due to the KTILE = 2R = 2C choice; utilization formula: `KT / (KT + R + C - 2)` |

---

## Platforms

- **CPU:** Intel Core i7-9700, 8 cores, 3.0 GHz base
- **GPU:** NVIDIA RTX 2080, 8 GB GDDR6
- **Accelerator:** SystemVerilog RTL simulated under VCS; architectural projections at 200 MHz
