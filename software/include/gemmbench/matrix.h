#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace gemmbench {

struct MatrixF32 {
  std::size_t rows{};
  std::size_t cols{};
  std::vector<float> data{};

  MatrixF32() = default;
  MatrixF32(std::size_t r, std::size_t c) : rows(r), cols(c), data(r * c) {}

  float* ptr() { return data.data(); }
  const float* ptr() const { return data.data(); }

  float& operator()(std::size_t r, std::size_t c) { return data[r * cols + c]; }
  const float& operator()(std::size_t r, std::size_t c) const { return data[r * cols + c]; }
};

void fill_deterministic(MatrixF32& m, std::uint64_t seed);
void zero(MatrixF32& m);

}

