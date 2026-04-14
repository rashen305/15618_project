#include "gemmbench/matrix.h"

#include <random>

namespace gemmbench {

void fill_deterministic(MatrixF32& m, std::uint64_t seed) {
  //use a fixed rng and distribution so runs are reproducible
  std::mt19937_64 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for (auto& x : m.data) x = dist(rng);
}

void zero(MatrixF32& m) {
  //used when a kernel accumulates into c
  for (auto& x : m.data) x = 0.0f;
}

}

