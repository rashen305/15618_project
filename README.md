# Accelerating GEMM with a Systolic Array on FPGA

**Albert Luo, Raymond Shen**  
15-418/618 Final Project  

---

## Overview

This project investigates how **dense matrix multiplication (GEMM)** maps onto different parallel architectures by designing and implementing a **parameterized systolic array accelerator on an AMD Artix-7 FPGA**, and comparing it against optimized CPU and GPU baselines.

Although GEMM exposes significant parallelism, high performance depends on careful coordination of **computation, data movement, and memory hierarchy**. We study how these factors interact across fundamentally different platforms: multicore CPUs, GPUs, and spatial FPGA accelerators.

---

## Design

### FPGA Accelerator
- Parameterized **2D systolic array** of processing elements (PEs)  
- Pipelined **multiply-accumulate (MAC)** units  
- Streaming dataflow (A horizontal, B vertical, local accumulation)  
- On-chip buffering and **tiled execution**  
- Controller for data movement and pipeline orchestration  

### Baselines
- **CPU:** OpenMP + cache blocking + SIMD  
- **GPU:** CUDA with shared memory tiling  

---

## Architectural Exploration

We evaluate how performance depends on key design parameters:
- **Array size and shape** (e.g., 4×4, 8×8, 16×16)  
- **Dataflow strategies** (output-stationary vs. weight-stationary)  
- **Buffering techniques** (single vs. double buffering)  
- **Tiling strategies** for large matrices  

---

## Evaluation

We perform a cross-platform comparison using:
- **Throughput (GFLOP/s)** and latency  
- **FPGA resource utilization** (DSP, BRAM, LUT)  
- **Parallel efficiency** and utilization  
- **Roofline analysis** to identify compute- vs memory-bound regimes  

---

## Goals

- Working FPGA systolic array implementation  
- Optimized CPU and GPU baselines  
- Benchmark suite across matrix sizes  
- Analysis grounded in 15-418 concepts:
  - pipeline utilization  
  - memory bandwidth  
  - communication vs computation  

---

## Key Insight

This project demonstrates that high-performance GEMM is not purely embarrassingly parallel. Performance is often limited by **data movement and memory constraints**, and depends critically on how computation is mapped onto the underlying architecture.

---
