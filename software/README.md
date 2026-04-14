# GEMM Benchmark Harness (CPU/GPU baselines)

This directory contains a minimal benchmark harness for GEMM.

**CPU:** `ref` (reference), `cpu_naive` (single-thread i–k–j), `cpu_omp` (OpenMP + cache blocking).

**GPU (CUDA):** `gpu_naive` (global memory, one thread per output element), `gpu_tiled` (shared-memory tile; `--tile` **16** or **32**, default **16** if unset or any other value).

## Build

From `15618_project/software`:

```bash
make -j
```

- Requires **OpenMP** (`-fopenmp` with `g++`).
- If `$(CUDA_HOME)/bin/nvcc` exists, the build enables CUDA (`-DGEMMBENCH_USE_CUDA`) and links `libcudart`. If `nvcc` is missing, you get a **CPU-only** binary; GPU backends will error at runtime with a clear message.

Useful overrides:

```bash
make CUDA_HOME=/path/to/cuda CUDA_ARCH=sm_89 -j
make USE_CUDA=0 -j          # CPU only, no nvcc
```

`nvcc` often needs an older host compiler; the Makefile defaults `NVCC_HOST_CXX` to `g++-11` when present (`g++-10`, then `g++`).

## Run

Reference:

```bash
./build/gemmbench --backend ref --size 256 --iters 3 --check 1
```

Naive CPU:

```bash
./build/gemmbench --backend cpu_naive --size 512 --iters 3 --check 1
```

OpenMP + blocked CPU (`--tile` = cache block size; default 64):

```bash
./build/gemmbench --backend cpu_omp --size 1024 --tile 64 --iters 5 --check 1
```

GPU naive / tiled (each timed call includes H2D + kernel + D2H):

```bash
./build/gemmbench --backend gpu_naive --size 1024 --iters 20 --check 1
./build/gemmbench --backend gpu_tiled --size 1024 --tile 16 --iters 20 --check 1
```

Rectangular GEMM:

```bash
./build/gemmbench --backend ref --m 256 --n 512 --k 128 --iters 3 --check 1
```

## Output format

One line per run, for example:

`backend=gpu_tiled M=1024 N=1024 K=1024 iters=5 sec_total=... sec_per_iter=... gflops=... check=PASS ...`

GPU tiled may show slightly larger float differences vs `ref` under `--check 1`; the harness uses a loose tolerance (`1e-3`).
