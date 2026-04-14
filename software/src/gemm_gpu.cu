#include "gemmbench/gemm_gpu.h"

#include <cuda_runtime.h>

#include <cstddef>
#include <stdexcept>
#include <string>

namespace gemmbench {
namespace detail {

#define CUDA_CHECK(stmt)                                                         \
  do {                                                                           \
    const cudaError_t _err = (stmt);                                             \
    if (_err != cudaSuccess) {                                                   \
      throw std::runtime_error(std::string("CUDA error: ") +                     \
                               cudaGetErrorString(_err));                        \
    }                                                                            \
  } while (0)

//one thread computes one c element
__global__ void gemm_naive_kernel(const float* __restrict__ A,
                                  const float* __restrict__ B,
                                  float* __restrict__ C, int M, int N, int K) {
  const int col = blockIdx.x * blockDim.x + threadIdx.x;
  const int row = blockIdx.y * blockDim.y + threadIdx.y;
  if (row >= M || col >= N) return;
  float acc = 0.f;
  for (int kk = 0; kk < K; ++kk) {
    acc += A[row * K + kk] * B[kk * N + col];
  }
  C[row * N + col] = acc;
}

template <int TILE>
//shared memory tiling reduces global loads
__global__ void gemm_tiled_kernel(const float* __restrict__ A,
                                  const float* __restrict__ B,
                                  float* __restrict__ C, int M, int N, int K) {
  __shared__ float As[TILE][TILE];
  __shared__ float Bs[TILE][TILE];

  const int bx = blockIdx.x;
  const int by = blockIdx.y;
  const int tx = threadIdx.x;
  const int ty = threadIdx.y;

  const int Row = by * TILE + ty;
  const int Col = bx * TILE + tx;

  float acc = 0.f;
  const int num_tiles = (K + TILE - 1) / TILE;

  for (int ph = 0; ph < num_tiles; ++ph) {
    const int a_col = ph * TILE + tx;
    if (Row < M && a_col < K) {
      As[ty][tx] = A[Row * K + a_col];
    } else {
      As[ty][tx] = 0.f;
    }

    const int b_row = ph * TILE + ty;
    if (b_row < K && Col < N) {
      Bs[ty][tx] = B[b_row * N + Col];
    } else {
      Bs[ty][tx] = 0.f;
    }

    __syncthreads();

#pragma unroll
    for (int k = 0; k < TILE; ++k) {
      acc += As[ty][k] * Bs[k][tx];
    }

    __syncthreads();
  }

  if (Row < M && Col < N) {
    C[Row * N + Col] = acc;
  }
}

float* d_A = nullptr;
float* d_B = nullptr;
float* d_C = nullptr;
std::size_t cap_a = 0;
std::size_t cap_b = 0;
std::size_t cap_c = 0;

void ensure_device_buffers(std::size_t m, std::size_t n, std::size_t k) {
  //reallocate only when a bigger capacity is needed
  const std::size_t need_a = m * k;
  const std::size_t need_b = k * n;
  const std::size_t need_c = m * n;

  auto grow = [](float*& ptr, std::size_t& cap, std::size_t need) {
    if (need > cap) {
      if (ptr) CUDA_CHECK(cudaFree(ptr));
      CUDA_CHECK(cudaMalloc(&ptr, need * sizeof(float)));
      cap = need;
    }
  };

  grow(d_A, cap_a, need_a);
  grow(d_B, cap_b, need_b);
  grow(d_C, cap_c, need_c);
}

}  // namespace detail

void gemm_gpu_naive(const MatrixF32& a, const MatrixF32& b, MatrixF32& c) {
  //this wrapper includes h2d and d2h copies
  const int M = static_cast<int>(a.rows);
  const int K = static_cast<int>(a.cols);
  const int N = static_cast<int>(b.cols);
  if (static_cast<int>(b.rows) != K || static_cast<int>(c.rows) != M ||
      static_cast<int>(c.cols) != N) {
    throw std::invalid_argument("gemm_gpu_naive: dimension mismatch");
  }

  detail::ensure_device_buffers(static_cast<std::size_t>(M),
                                static_cast<std::size_t>(N),
                                static_cast<std::size_t>(K));

  CUDA_CHECK(cudaMemcpy(detail::d_A, a.ptr(), M * K * sizeof(float), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(detail::d_B, b.ptr(), K * N * sizeof(float), cudaMemcpyHostToDevice));

  dim3 block(16, 16);
  dim3 grid((N + block.x - 1) / block.x, (M + block.y - 1) / block.y);
  detail::gemm_naive_kernel<<<grid, block>>>(detail::d_A, detail::d_B, detail::d_C, M, N, K);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  CUDA_CHECK(cudaMemcpy(c.ptr(), detail::d_C, M * N * sizeof(float), cudaMemcpyDeviceToHost));
}

void gemm_gpu_tiled(const MatrixF32& a, const MatrixF32& b, MatrixF32& c,
                    std::size_t tile) {
  //tile is a thread block dimension
  const int M = static_cast<int>(a.rows);
  const int K = static_cast<int>(a.cols);
  const int N = static_cast<int>(b.cols);
  if (static_cast<int>(b.rows) != K || static_cast<int>(c.rows) != M ||
      static_cast<int>(c.cols) != N) {
    throw std::invalid_argument("gemm_gpu_tiled: dimension mismatch");
  }

  detail::ensure_device_buffers(static_cast<std::size_t>(M),
                                static_cast<std::size_t>(N),
                                static_cast<std::size_t>(K));

  CUDA_CHECK(cudaMemcpy(detail::d_A, a.ptr(), M * K * sizeof(float), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(detail::d_B, b.ptr(), K * N * sizeof(float), cudaMemcpyHostToDevice));

  if (tile == 32) {
    constexpr int TILE = 32;
    dim3 block(TILE, TILE);
    dim3 grid((N + TILE - 1) / TILE, (M + TILE - 1) / TILE);
    detail::gemm_tiled_kernel<TILE><<<grid, block>>>(detail::d_A, detail::d_B, detail::d_C, M,
                                                     N, K);
  } else {
    constexpr int TILE = 16;
    dim3 block(TILE, TILE);
    dim3 grid((N + TILE - 1) / TILE, (M + TILE - 1) / TILE);
    detail::gemm_tiled_kernel<TILE><<<grid, block>>>(detail::d_A, detail::d_B, detail::d_C, M,
                                                     N, K);
  }

  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());

  CUDA_CHECK(cudaMemcpy(c.ptr(), detail::d_C, M * N * sizeof(float), cudaMemcpyDeviceToHost));
}

}
