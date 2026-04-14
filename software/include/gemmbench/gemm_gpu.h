#pragma once

#include <cstddef>

#include "gemmbench/matrix.h"

namespace gemmbench {

//host wrappers include h2d kernel d2h
//device buffers are reused when possible
void gemm_gpu_naive(const MatrixF32& a, const MatrixF32& b, MatrixF32& c);

//shared memory tiled gemm. tile is 16 or 32
void gemm_gpu_tiled(const MatrixF32& a, const MatrixF32& b, MatrixF32& c,
                    std::size_t tile);

}
