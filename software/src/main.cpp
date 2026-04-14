#include "gemmbench/gemm.h"
#include "gemmbench/matrix.h"
#include "gemmbench/validate.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>

namespace {

struct Args {
  gemmbench::Backend backend = gemmbench::Backend::Ref;
  std::size_t m = 1024;
  std::size_t n = 1024;
  std::size_t k = 1024;
  std::size_t tile = 64;
  int iters = 5;
  std::uint64_t seed = 1;
  bool check = false;
  bool warmup = true;
};

std::optional<std::size_t> parse_size(std::string_view s) {
  //simple parser to keep the harness dependency free
  if (s.empty()) return std::nullopt;
  std::size_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return std::nullopt;
    v = v * 10 + static_cast<std::size_t>(c - '0');
  }
  return v;
}

std::optional<std::uint64_t> parse_u64(std::string_view s) {
  if (s.empty()) return std::nullopt;
  std::uint64_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return std::nullopt;
    v = v * 10 + static_cast<std::uint64_t>(c - '0');
  }
  return v;
}

std::optional<int> parse_int(std::string_view s) {
  if (s.empty()) return std::nullopt;
  int sign = 1;
  std::size_t i = 0;
  if (s[0] == '-') {
    sign = -1;
    i = 1;
  }
  if (i >= s.size()) return std::nullopt;
  int v = 0;
  for (; i < s.size(); ++i) {
    const char c = s[i];
    if (c < '0' || c > '9') return std::nullopt;
    v = v * 10 + (c - '0');
  }
  return sign * v;
}

[[noreturn]] void usage(const char* prog) {
  std::cerr
      << "Usage:\n"
      << "  " << prog
      << " [--backend ref|cpu_naive|cpu_omp|gpu_naive|gpu_tiled]\n"
      << "       [--size N | --m M --n N --k K]\n"
      << "       [--tile T] [--iters I] [--seed S] [--check 0|1] [--warmup 0|1]\n"
      << "\n"
      << "Examples:\n"
      << "  " << prog << " --backend ref --size 512 --iters 3 --check 1\n"
      << "  " << prog << " --backend cpu_omp --size 1024 --tile 64 --iters 5\n"
      << "  " << prog << " --backend gpu_tiled --size 1024 --tile 16 --iters 20 --check 1\n"
      << "  " << prog << " --m 256 --n 256 --k 512 --iters 5\n";
  std::exit(2);
}

Args parse_args(int argc, char** argv) {
  Args a{};
  for (int i = 1; i < argc; ++i) {
    const std::string_view arg(argv[i]);
    auto need_value = [&](std::string_view name) -> std::string_view {
      if (i + 1 >= argc) {
        std::cerr << "Missing value for " << name << "\n";
        usage(argv[0]);
      }
      return std::string_view(argv[++i]);
    };

    if (arg == "--help" || arg == "-h") {
      usage(argv[0]);
    } else if (arg == "--backend") {
      a.backend = gemmbench::parse_backend(need_value("--backend"));
    } else if (arg == "--size") {
      const auto v = parse_size(need_value("--size"));
      if (!v) usage(argv[0]);
      a.m = *v;
      a.n = *v;
      a.k = *v;
    } else if (arg == "--m") {
      const auto v = parse_size(need_value("--m"));
      if (!v) usage(argv[0]);
      a.m = *v;
    } else if (arg == "--n") {
      const auto v = parse_size(need_value("--n"));
      if (!v) usage(argv[0]);
      a.n = *v;
    } else if (arg == "--k") {
      const auto v = parse_size(need_value("--k"));
      if (!v) usage(argv[0]);
      a.k = *v;
    } else if (arg == "--tile") {
      const auto v = parse_size(need_value("--tile"));
      if (!v) usage(argv[0]);
      a.tile = *v;
    } else if (arg == "--iters") {
      const auto v = parse_int(need_value("--iters"));
      if (!v) usage(argv[0]);
      a.iters = *v;
    } else if (arg == "--seed") {
      const auto v = parse_u64(need_value("--seed"));
      if (!v) usage(argv[0]);
      a.seed = *v;
    } else if (arg == "--check") {
      const auto v = parse_int(need_value("--check"));
      if (!v) usage(argv[0]);
      a.check = (*v != 0);
    } else if (arg == "--warmup") {
      const auto v = parse_int(need_value("--warmup"));
      if (!v) usage(argv[0]);
      a.warmup = (*v != 0);
    } else {
      std::cerr << "Unknown arg: " << arg << "\n";
      usage(argv[0]);
    }
  }

  if (a.m == 0 || a.n == 0 || a.k == 0) {
    std::cerr << "Matrix dims must be > 0\n";
    usage(argv[0]);
  }
  if (a.iters <= 0) {
    std::cerr << "--iters must be > 0\n";
    usage(argv[0]);
  }
  return a;
}

double gflops(std::size_t m, std::size_t n, std::size_t k, double seconds) {
  //gflops uses 2 m n k floating point ops for gemm
  const double flops = 2.0 * static_cast<double>(m) * static_cast<double>(n) *
                       static_cast<double>(k);
  return (seconds > 0.0) ? (flops / seconds / 1e9) : 0.0;
}

}

int main(int argc, char** argv) {
  try {
    const Args args = parse_args(argc, argv);

    gemmbench::MatrixF32 a(args.m, args.k);
    gemmbench::MatrixF32 b(args.k, args.n);
    gemmbench::MatrixF32 c(args.m, args.n);

    gemmbench::fill_deterministic(a, args.seed);
    gemmbench::fill_deterministic(b, args.seed + 1);
    gemmbench::zero(c);

    if (args.warmup) {
      //warmup is not included in timing
      gemmbench::gemm(args.backend, a, b, c, args.tile);
      gemmbench::zero(c);
    }

    //time includes iters calls to gemm
    const auto t0 = std::chrono::steady_clock::now();
    for (int it = 0; it < args.iters; ++it) {
      gemmbench::gemm(args.backend, a, b, c, args.tile);
    }
    const auto t1 = std::chrono::steady_clock::now();
    const std::chrono::duration<double> dt = t1 - t0;

    bool ok = true;
    gemmbench::ErrorStats stats{};
    if (args.check) {
      //always validate against the ref backend
      gemmbench::MatrixF32 cref(args.m, args.n);
      gemmbench::zero(cref);
      gemmbench::gemm(gemmbench::Backend::Ref, a, b, cref, 0);
      stats = gemmbench::compute_error_stats(cref, c);
      ok = (stats.max_abs_err <= 1e-3f) || (stats.max_rel_err <= 1e-3f);
    }

    const double seconds = dt.count();
    const double perf = gflops(args.m, args.n, args.k, seconds / args.iters);

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "backend=" << gemmbench::backend_name(args.backend) << " ";
    std::cout << "M=" << args.m << " N=" << args.n << " K=" << args.k << " ";
    std::cout << "iters=" << args.iters << " ";
    std::cout << "sec_total=" << seconds << " ";
    std::cout << "sec_per_iter=" << (seconds / args.iters) << " ";
    std::cout << "gflops=" << perf;

    if (args.check) {
      std::cout << " check=" << (ok ? "PASS" : "FAIL");
      std::cout << " max_abs=" << stats.max_abs_err;
      std::cout << " max_rel=" << stats.max_rel_err;
    }
    std::cout << "\n";

    return ok ? 0 : 1;
  } catch (const std::exception& e) {
    std::cerr << "Error: " << e.what() << "\n";
    return 2;
  }
}

