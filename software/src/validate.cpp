#include "gemmbench/validate.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace gemmbench {

ErrorStats compute_error_stats(const MatrixF32& ref, const MatrixF32& out) {
  //max errors make it easy to set tolerances for gpu kernels
  ErrorStats s{};
  if (ref.rows != out.rows || ref.cols != out.cols) {
    s.max_abs_err = std::numeric_limits<float>::infinity();
    s.max_rel_err = std::numeric_limits<float>::infinity();
    s.max_abs_idx = 0;
    s.max_rel_idx = 0;
    return s;
  }

  const std::size_t n = ref.data.size();
  float max_abs = 0.0f;
  float max_rel = 0.0f;
  std::size_t max_abs_i = 0;
  std::size_t max_rel_i = 0;

  for (std::size_t i = 0; i < n; ++i) {
    const float r = ref.data[i];
    const float o = out.data[i];
    const float abs_err = std::fabs(o - r);

    //denom clamp avoids huge relative error near zero
    const float denom = std::max(1e-6f, std::fabs(r));
    const float rel_err = abs_err / denom;

    if (abs_err > max_abs) {
      max_abs = abs_err;
      max_abs_i = i;
    }
    if (rel_err > max_rel) {
      max_rel = rel_err;
      max_rel_i = i;
    }
  }

  s.max_abs_err = max_abs;
  s.max_rel_err = max_rel;
  s.max_abs_idx = max_abs_i;
  s.max_rel_idx = max_rel_i;
  return s;
}

}

