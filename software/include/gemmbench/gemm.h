#pragma once

#include <cstddef>
#include <string_view>

#include "gemmbench/matrix.h"

namespace gemmbench {

enum class Backend {
  Ref,
  CpuNaive,
  CpuOmpBlocked,
  GpuNaive,
  GpuTiled,
};

enum class TimingMode {
  EndToEnd,
  ComputeOnly,
};

Backend parse_backend(std::string_view s);
const char* backend_name(Backend b);
TimingMode parse_timing_mode(std::string_view s);
const char* timing_mode_name(TimingMode m);

//computes c = a * b with row major matrices
//tile is cpu_omp block size. gpu_tiled uses 16 or 32
void gemm(Backend backend, const MatrixF32& a, const MatrixF32& b, MatrixF32& c,
          std::size_t tile = 0, TimingMode timing_mode = TimingMode::EndToEnd);

}
