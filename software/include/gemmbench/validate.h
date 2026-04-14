#pragma once

#include <cstddef>

#include "gemmbench/matrix.h"

namespace gemmbench {

struct ErrorStats {
  float max_abs_err{};
  float max_rel_err{};
  std::size_t max_abs_idx{};
  std::size_t max_rel_idx{};
};

ErrorStats compute_error_stats(const MatrixF32& ref, const MatrixF32& out);

}

