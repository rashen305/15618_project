#!/usr/bin/env python3
"""Run reproducible GEMM benchmark sweeps and write normalized CSV output."""

from __future__ import annotations

import argparse
import csv
import pathlib
import shlex
import subprocess
import sys
from typing import Iterable


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_BIN = ROOT / "build" / "gemmbench"


def parse_list(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_kv_line(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in line.strip().split():
        if "=" not in token:
            continue
        key, val = token.split("=", 1)
        result[key] = val
    return result


def run_command(cmd: list[str], cwd: pathlib.Path) -> dict[str, str]:
    proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    if proc.returncode != 0:
        quoted = " ".join(shlex.quote(part) for part in cmd)
        sys.stderr.write(f"Command failed: {quoted}\n")
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)

    for line in reversed(proc.stdout.splitlines()):
        parsed = parse_kv_line(line)
        if parsed:
            parsed["raw_output"] = line
            return parsed

    raise RuntimeError(f"No key=value benchmark line found in output: {proc.stdout!r}")


def add_common_args(cmd: list[str], args: argparse.Namespace, backend: str) -> None:
    cmd += ["--backend", backend, "--iters", str(args.iters), "--seed", str(args.seed)]
    cmd += ["--check", "1" if args.check else "0"]
    cmd += ["--warmup", "1" if args.warmup else "0"]
    if args.tile:
        cmd += ["--tile", str(args.tile)]


def sweep_square(args: argparse.Namespace) -> Iterable[dict[str, str]]:
    sizes = [int(v) for v in parse_list(args.sizes)]
    backends = parse_list(args.backends)

    for backend in backends:
        for size in sizes:
            for repeat in range(args.repeats):
                cmd = [str(args.binary), "--size", str(size)]
                add_common_args(cmd, args, backend)
                row = run_command(cmd, ROOT)
                row["repeat"] = str(repeat)
                row["command"] = " ".join(shlex.quote(part) for part in cmd)
                yield row


def sweep_rect(args: argparse.Namespace) -> Iterable[dict[str, str]]:
    backends = parse_list(args.backends)
    shapes = []
    for shape in parse_list(args.shapes):
        dims = shape.lower().split("x")
        if len(dims) != 3:
            raise SystemExit(f"Invalid shape {shape!r}; expected MxNxK")
        shapes.append(tuple(int(v) for v in dims))

    for backend in backends:
        for m, n, k in shapes:
            for repeat in range(args.repeats):
                cmd = [str(args.binary), "--m", str(m), "--n", str(n), "--k", str(k)]
                add_common_args(cmd, args, backend)
                row = run_command(cmd, ROOT)
                row["repeat"] = str(repeat)
                row["command"] = " ".join(shlex.quote(part) for part in cmd)
                yield row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=pathlib.Path, default=DEFAULT_BIN)
    parser.add_argument("--out", type=pathlib.Path, default=ROOT / "build" / "sweep.csv")
    parser.add_argument("--backends", default="ref,cpu_naive,cpu_omp,gpu_naive,gpu_tiled")
    parser.add_argument("--sizes", default="128,256,512,1024")
    parser.add_argument("--shapes", default="", help="Optional comma list of MxNxK rectangular shapes.")
    parser.add_argument("--iters", type=int, default=5)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--tile", type=int, default=64)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--check", type=int, default=1)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--build", action="store_true", help="Run make before the sweep.")
    parser.add_argument("--cpu-only", action="store_true", help="Build with USE_CUDA=0 when --build is set.")
    args = parser.parse_args()

    if args.build:
        make_cmd = ["make", "-j"]
        if args.cpu_only:
            make_cmd.append("USE_CUDA=0")
        subprocess.run(make_cmd, cwd=ROOT, check=True)

    if not args.binary.exists():
        raise SystemExit(f"Benchmark binary not found: {args.binary}")

    args.out.parent.mkdir(parents=True, exist_ok=True)

    rows = list(sweep_rect(args) if args.shapes else sweep_square(args))
    preferred = [
        "backend",
        "M",
        "N",
        "K",
        "iters",
        "sec_total",
        "sec_per_iter",
        "gflops",
        "check",
        "max_abs",
        "max_rel",
        "repeat",
        "command",
        "raw_output",
    ]
    extra = sorted({key for row in rows for key in row} - set(preferred))
    fieldnames = preferred + extra

    with args.out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
