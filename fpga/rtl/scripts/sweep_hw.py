#!/usr/bin/env python3
"""Sweep SystemVerilog GEMM accelerator parameters and write CSV results."""

from __future__ import annotations

import argparse
import csv
import pathlib
import shlex
import subprocess
import sys
from dataclasses import dataclass


RTL_DIR = pathlib.Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class ArrayCfg:
    rows: int
    cols: int
    ktile: int


@dataclass(frozen=True)
class Shape:
    m: int
    n: int
    k: int


@dataclass(frozen=True)
class MemCfg:
    read_lat: int
    write_lat: int
    read_gap: int
    write_gap: int


def split_list(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_array_cfgs(value: str) -> list[ArrayCfg]:
    cfgs: list[ArrayCfg] = []
    for item in split_list(value):
        parts = item.lower().split("x")
        if len(parts) != 3:
            raise SystemExit(f"Invalid array config {item!r}; expected ROWSxCOLSxKTILE")
        cfgs.append(ArrayCfg(*(int(part) for part in parts)))
    return cfgs


def parse_shapes(value: str) -> list[Shape]:
    shapes: list[Shape] = []
    for item in split_list(value):
        parts = item.lower().split("x")
        if len(parts) != 3:
            raise SystemExit(f"Invalid GEMM shape {item!r}; expected MxNxK")
        shapes.append(Shape(*(int(part) for part in parts)))
    return shapes


def parse_mem_cfgs(value: str) -> list[MemCfg]:
    cfgs: list[MemCfg] = []
    for item in split_list(value):
        parts = item.split(":")
        if len(parts) == 2:
            read_lat, write_lat = (int(part) for part in parts)
            cfgs.append(MemCfg(read_lat, write_lat, 0, 0))
        elif len(parts) == 4:
            read_lat, write_lat, read_gap, write_gap = (int(part) for part in parts)
            cfgs.append(MemCfg(read_lat, write_lat, read_gap, write_gap))
        else:
            raise SystemExit(
                f"Invalid memory config {item!r}; expected read:write or read:write:read_gap:write_gap"
            )
    return cfgs


def parse_sv_csv(stdout: str) -> dict[str, str]:
    header: list[str] | None = None
    for line in stdout.splitlines():
        if line.startswith("fpga_bench_header,"):
            header = next(csv.reader([line]))
        elif line.startswith("fpga_bench,"):
            if header is None:
                raise RuntimeError("Found fpga_bench row before fpga_bench_header")
            values = next(csv.reader([line]))
            return dict(zip(header, values))
    raise RuntimeError(f"No fpga_bench CSV row found in simulator output:\n{stdout}")


def run_case(args: argparse.Namespace, cfg: ArrayCfg, shape: Shape, mem: MemCfg,
             double_buffer: int) -> dict[str, str]:
    make_cmd = [
        "make",
        "bench-sa",
        f"ROWS={cfg.rows}",
        f"COLS={cfg.cols}",
        f"KTILE={cfg.ktile}",
        f"M={shape.m}",
        f"N={shape.n}",
        f"K={shape.k}",
        f"READ_LAT={mem.read_lat}",
        f"WRITE_LAT={mem.write_lat}",
        f"READ_GAP={mem.read_gap}",
        f"WRITE_GAP={mem.write_gap}",
        f"CLOCK_MHZ={args.clock_mhz}",
        f"DBUF={double_buffer}",
    ]

    if args.clean_between:
        subprocess.run(["make", "clean"], cwd=args.rtl_dir, check=True)

    proc = subprocess.run(make_cmd, cwd=args.rtl_dir, text=True, capture_output=True)
    quoted = " ".join(shlex.quote(part) for part in make_cmd)
    if proc.returncode != 0:
        sys.stderr.write(f"Command failed: {quoted}\n")
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)

    row = parse_sv_csv(proc.stdout)
    row["command"] = quoted
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl-dir", type=pathlib.Path, default=RTL_DIR)
    parser.add_argument("--out", type=pathlib.Path, default=RTL_DIR / "build" / "fpga_sweep.csv")
    parser.add_argument("--arrays", default="2x2x4,4x4x8,8x4x8")
    parser.add_argument("--shapes", default="8x8x8,16x16x16,32x32x32")
    parser.add_argument("--mem", default="20:10,40:20,80:40:1:1")
    parser.add_argument("--double-buffer", default="1,0")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--clock-mhz", type=int, default=100)
    parser.add_argument("--clean-between", action="store_true")
    args = parser.parse_args()

    args.rtl_dir = args.rtl_dir.resolve()
    arrays = parse_array_cfgs(args.arrays)
    shapes = parse_shapes(args.shapes)
    mem_cfgs = parse_mem_cfgs(args.mem)
    double_buffers = [int(v) for v in split_list(args.double_buffer)]

    args.out.parent.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, str]] = []

    for repeat in range(args.repeats):
        for cfg in arrays:
            for shape in shapes:
                for mem in mem_cfgs:
                    for dbuf in double_buffers:
                        row = run_case(args, cfg, shape, mem, dbuf)
                        row["repeat"] = str(repeat)
                        rows.append(row)
                        print(
                            "done",
                            f"repeat={repeat}",
                            f"array={cfg.rows}x{cfg.cols}x{cfg.ktile}",
                            f"shape={shape.m}x{shape.n}x{shape.k}",
                            f"mem={mem.read_lat}:{mem.write_lat}:{mem.read_gap}:{mem.write_gap}",
                            f"dbuf={dbuf}",
                        )

    preferred = [
        "repeat",
        "rows",
        "cols",
        "k_tile",
        "m",
        "n",
        "k",
        "double_buffer",
        "mem_read_lat",
        "mem_write_lat",
        "read_gap",
        "write_gap",
        "banks",
        "row_words",
        "row_hit",
        "row_miss",
        "clock_mhz",
        "cycles",
        "compute_cycles",
        "mem_stall_cycles",
        "prefetch_cycles",
        "compute_wait_cycles",
        "reads",
        "writes",
        "bytes_read",
        "bytes_written",
        "loaded_k_tiles",
        "output_tiles",
        "ops_per_cycle",
        "projected_gflops",
        "pe_util",
        "arithmetic_intensity",
        "command",
    ]
    extra = sorted({key for row in rows for key in row} - set(preferred))

    with args.out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=preferred + extra)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
