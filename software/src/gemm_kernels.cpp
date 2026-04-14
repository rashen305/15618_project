#include "gemmbench/gemm.h"

#ifdef GEMMBENCH_USE_CUDA
#include "gemmbench/gemm_gpu.h"
#endif

#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <string>

namespace gemmbench {

namespace {

constexpr std::size_t kDefaultTile = 64;

void check_dims(const MatrixF32& a, const MatrixF32& b, const MatrixF32& c) {
  const std::size_t m = a.rows;
  const std::size_t k = a.cols;
  const std::size_t n = b.cols;
  if (b.rows != k || c.rows != m || c.cols != n) {
    throw std::invalid_argument("gemm: dimension mismatch");
  }
}

//reference baseline for correctness
void gemm_ref(const MatrixF32& a, const MatrixF32& b, MatrixF32& c) {
  const std::size_t m = a.rows;
  const std::size_t k = a.cols;
  const std::size_t n = b.cols;
  check_dims(a, b, c);

  for (std::size_t i = 0; i < m; ++i) {
    for (std::size_t j = 0; j < n; ++j) {
      float acc = 0.0f;
      for (std::size_t kk = 0; kk < k; ++kk) {
        acc += a(i, kk) * b(kk, j);
      }
      c(i, j) = acc;
    }
  }
}

//single thread kernel with better locality than ref
void gemm_cpu_naive(const MatrixF32& a, const MatrixF32& b, MatrixF32& c) {
  const std::size_t m = a.rows;
  const std::size_t k = a.cols;
  const std::size_t n = b.cols;
  check_dims(a, b, c);

  //c is cleared because this kernel uses +=
  std::memset(c.ptr(), 0, c.data.size() * sizeof(float));

  for (std::size_t i = 0; i < m; ++i) {
    for (std::size_t kk = 0; kk < k; ++kk) {
      const float aik = a(i, kk);
      for (std::size_t j = 0; j < n; ++j) {
        c(i, j) += aik * b(kk, j);
      }
    }
  }
}

void gemm_cpu_omp_blocked(const MatrixF32& a, const MatrixF32& b, MatrixF32& c,
                          std::size_t tile) {
  const std::size_t m = a.rows;
  const std::size_t kdim = a.cols;
  const std::size_t n = b.cols;
  check_dims(a, b, c);

  //tile is a cache block size
  if (tile == 0) tile = kDefaultTile;

  //c is cleared because this kernel uses +=
  std::memset(c.ptr(), 0, c.data.size() * sizeof(float));

#ifdef _OPENMP
//parallelize over output tiles
#pragma omp parallel for collapse(2) schedule(static)
#endif
  for (std::size_t ib = 0; ib < m; ib += tile) {
    for (std::size_t jb = 0; jb < n; jb += tile) {
      const std::size_t iend = std::min(ib + tile, m);
      const std::size_t jend = std::min(jb + tile, n);
      for (std::size_t kb = 0; kb < kdim; kb += tile) {
        const std::size_t kend = std::min(kb + tile, kdim);
        for (std::size_t i = ib; i < iend; ++i) {
          for (std::size_t kk = kb; kk < kend; ++kk) {
            const float aik = a(i, kk);
            for (std::size_t j = jb; j < jend; ++j) {
              c(i, j) += aik * b(kk, j);
            }
          }
        }
      }
    }
  }
}

}

Backend parse_backend(std::string_view s) {
  if (s == "ref") return Backend::Ref;
  if (s == "cpu_naive") return Backend::CpuNaive;
  if (s == "cpu_omp") return Backend::CpuOmpBlocked;
  if (s == "gpu_naive") return Backend::GpuNaive;
  if (s == "gpu_tiled") return Backend::GpuTiled;
  throw std::invalid_argument("unknown backend: " + std::string(s));
}

const char* backend_name(Backend b) {
  switch (b) {
    case Backend::Ref:
      return "ref";
    case Backend::CpuNaive:
      return "cpu_naive";
    case Backend::CpuOmpBlocked:
      return "cpu_omp";
    case Backend::GpuNaive:
      return "gpu_naive";
    case Backend::GpuTiled:
      return "gpu_tiled";
  }
  return "unknown";
}

void gemm(Backend backend, const MatrixF32& a, const MatrixF32& b, MatrixF32& c,
          std::size_t tile) {
  switch (backend) {
    case Backend::Ref:
      gemm_ref(a, b, c);
      return;
    case Backend::CpuNaive:
      gemm_cpu_naive(a, b, c);
      return;
    case Backend::CpuOmpBlocked:
#ifndef _OPENMP
      (void)tile;
      throw std::runtime_error("cpu_omp backend requires OpenMP (-fopenmp)");
#else
      gemm_cpu_omp_blocked(a, b, c, tile);
      return;
#endif
    case Backend::GpuNaive:
    case Backend::GpuTiled:
#ifndef GEMMBENCH_USE_CUDA
      (void)tile;
      throw std::runtime_error(
          "GPU backends require CUDA (rebuild with USE_CUDA=1 and nvcc in CUDA_HOME)");
#else
      //this path keeps the same c a b interface as cpu
      if (backend == Backend::GpuNaive) {
        gemm_gpu_naive(a, b, c);
      } else {
        gemm_gpu_tiled(a, b, c, tile);
      }
      return;
#endif
  }
  throw std::invalid_argument("gemm: unsupported backend");
}

}
