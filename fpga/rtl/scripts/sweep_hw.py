#!/usr/bin/env python3
"""Sweep systolic GEMM engine parameters, collect CSV, and make report plots.

Python 3.6.8 compatible. No dataclasses, no list[str], no capture_output.

Examples:
  python3.6 scripts/sweep_hw.py --rtl-dir .
  python3.6 scripts/sweep_hw.py --arrays 2x8x8,4x4x8,8x8x16 --shapes 32x32x32,64x64x64
  python3.6 scripts/sweep_hw.py --mem l1,l2,llc,dram
  python3.6 scripts/sweep_hw.py --mem L1=4:1:0:0:64:16:64:1:0:0,L2=12:4:0:0:32:8:128:1:0:0

Memory config format:
  profile-name or read_lat:write_lat[:read_gap:write_gap[:max_out:banks:row_words:row_hit:row_miss:row_buf]]

Built-in profiles: l1, l2, llc, dram. For l1/l2/llc, row_buf=0, so READ_LAT/WRITE_LAT
are direct cache-hit latencies. The dram profile enables row-buffer behavior.
"""

from __future__ import print_function

import argparse
import csv
import math
import os
import pathlib
import shlex
import subprocess
import sys

RTL_DIR = pathlib.Path(__file__).resolve().parents[1]


class ArrayCfg(object):
    def __init__(self, rows, cols, ktile, label=None):
        self.rows = int(rows)
        self.cols = int(cols)
        self.ktile = int(ktile)
        self.label = label or ("%dx%dx%d" % (self.rows, self.cols, self.ktile))

    def __repr__(self):
        return self.label


class Shape(object):
    def __init__(self, m, n, k):
        self.m = int(m)
        self.n = int(n)
        self.k = int(k)

    def __repr__(self):
        return "%dx%dx%d" % (self.m, self.n, self.k)


class MemCfg(object):
    def __init__(self, read_lat, write_lat, read_gap=0, write_gap=0,
                 max_out=16, banks=4, row_words=1024, row_hit=12,
                 row_miss=28, row_buf=1, label=None):
        self.read_lat = int(read_lat)
        self.write_lat = int(write_lat)
        self.read_gap = int(read_gap)
        self.write_gap = int(write_gap)
        self.max_out = int(max_out)
        self.banks = int(banks)
        self.row_words = int(row_words)
        self.row_hit = int(row_hit)
        self.row_miss = int(row_miss)
        self.row_buf = int(row_buf)
        self.label = label

    def raw(self):
        return "%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % (
            self.read_lat, self.write_lat, self.read_gap, self.write_gap,
            self.max_out, self.banks, self.row_words, self.row_hit,
            self.row_miss, self.row_buf)

    def __repr__(self):
        if self.label:
            return "%s=%s" % (self.label, self.raw())
        return self.raw()


CACHE_MEM_PROFILES = {
    # Format: label -> MemCfg(read_lat, write_lat, read_gap, write_gap,
    #                         max_out, banks, row_words, row_hit, row_miss, row_buf)
    # For L1/L2/LLC cache-like runs, row_buf=0 makes READ_LAT/WRITE_LAT the actual hit latency.
    # These are intentionally simple cycle-level modeling points, not a full nonblocking cache model.
    "l1":  MemCfg(4,   1, 0, 0, 64, 16,  64, 1,  0, 0, "L1_hit"),
    "l2":  MemCfg(12,  4, 0, 0, 32,  8, 128, 1,  0, 0, "L2_hit"),
    "llc": MemCfg(36, 12, 1, 1, 16,  4, 512, 1,  0, 0, "LLC_hit"),
    # # DRAM-like profile: row buffer enabled; misses pay READ/WRITE base + ROW_MISS, hits pay ROW_HIT.
    # "dram": MemCfg(120, 60, 2, 2, 8, 4, 1024, 12, 60, 1, "DRAM_like"),
}

DEFAULT_MEM_PROFILE_ORDER = "l1,l2,llc"


def array_preset_string(name):
    """Return a comma-separated array sweep string.
    """
    key = (name or "large").lower()
    presets = {
        "small": "skinny_2x8=2x8x8,square_4=4x4x8,skinny_8x2=8x2x8,square_8=8x8x16",
        "large": "skinny_4x16=4x16x16,square_8=8x8x16,skinny_8x32=8x32x32,square_16=16x16x32,skinny_16x64=16x64x64,square_32=32x32x64,skinny_32x64=32x64x64,square_48=48x48x96,square_64=64x64x128",
        "gpu_scale": "square_16=16x16x32,square_32=32x32x64,square_48=48x48x96,square_64=64x64x128,square_80=80x80x160,square_96=96x96x192,square_128=128x128x256",
        "gpu_scale": "square_64=64x64x128,square_80=80x80x160,square_96=96x96x192,square_128=128x128x256",
        "huge": "square_64=64x64x128,square_96=96x96x192,square_128=128x128x256,square_192=192x192x384,square_256=256x256x512",
    }
    if key not in presets:
        raise SystemExit("Unknown --array-preset %r; choices are %s" % (name, ", ".join(sorted(presets))))
    return presets[key]


def split_list(value):
    if value is None:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_array_cfgs(value):
    cfgs = []
    for item in split_list(value):
        label = None
        if "=" in item:
            label, item = item.split("=", 1)
        parts = item.lower().split("x")
        if len(parts) != 3:
            raise SystemExit("Invalid array config %r; expected ROWSxCOLSxKTILE" % item)
        cfgs.append(ArrayCfg(int(parts[0]), int(parts[1]), int(parts[2]), label))
    return cfgs


def parse_shapes(value):
    shapes = []
    for item in split_list(value):
        parts = item.lower().split("x")
        if len(parts) != 3:
            raise SystemExit("Invalid GEMM shape %r; expected MxNxK" % item)
        shapes.append(Shape(int(parts[0]), int(parts[1]), int(parts[2])))
    return shapes


def parse_mem_cfgs(value):
    cfgs = []
    for item in split_list(value):
        label = None
        raw = item
        if "=" in item:
            label, raw = item.split("=", 1)
        key = raw.lower()
        if key in CACHE_MEM_PROFILES:
            prof = CACHE_MEM_PROFILES[key]
            cfgs.append(MemCfg(prof.read_lat, prof.write_lat, prof.read_gap, prof.write_gap,
                               prof.max_out, prof.banks, prof.row_words, prof.row_hit,
                               prof.row_miss, prof.row_buf, label or prof.label))
            continue
        parts = [int(part) for part in raw.split(":")]
        if len(parts) == 2:
            cfgs.append(MemCfg(parts[0], parts[1], label=label))
        elif len(parts) == 4:
            cfgs.append(MemCfg(parts[0], parts[1], parts[2], parts[3], label=label))
        elif len(parts) == 10:
            cfgs.append(MemCfg(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5],
                               parts[6], parts[7], parts[8], parts[9], label))
        else:
            raise SystemExit(
                "Invalid memory config %r; expected profile name (l1/l2/llc/dram), "
                "read:write, read:write:read_gap:write_gap, or "
                "read:write:read_gap:write_gap:max_out:banks:row_words:row_hit:row_miss:row_buf" % item)
    return cfgs


def parse_int_list(value):
    return [int(v) for v in split_list(value)]


def parse_sv_csv(stdout):
    header = None
    rows = []
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith("engine_bench_header,"):
            header = next(csv.reader([line]))[1:]
        elif line.startswith("engine_bench,"):
            if header is None:
                raise RuntimeError("Found engine_bench row before engine_bench_header")
            values = next(csv.reader([line]))[1:]
            rows.append(dict(zip(header, values)))
    if not rows:
        raise RuntimeError("No engine_bench CSV row found in simulator output:\n%s" % stdout)
    return rows[-1]


def run_cmd(cmd, cwd):
    proc = subprocess.Popen(cmd, cwd=str(cwd), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True)
    out, err = proc.communicate()
    quoted = " ".join(shlex.quote(str(part)) for part in cmd)
    if proc.returncode != 0:
        sys.stderr.write("Command failed: %s\n" % quoted)
        sys.stderr.write(out)
        sys.stderr.write(err)
        raise SystemExit(proc.returncode)
    return out, err, quoted


def run_case(args, cfg, shape, mem, dbuf, repeat):
    make_cmd = [
        "make", "bench-engine",
        "ROWS=%d" % cfg.rows,
        "COLS=%d" % cfg.cols,
        "KTILE=%d" % cfg.ktile,
        "M=%d" % shape.m,
        "N=%d" % shape.n,
        "K=%d" % shape.k,
        "READ_LAT=%d" % mem.read_lat,
        "WRITE_LAT=%d" % mem.write_lat,
        "READ_GAP=%d" % mem.read_gap,
        "WRITE_GAP=%d" % mem.write_gap,
        "MAX_OUT=%d" % mem.max_out,
        "BANKS=%d" % mem.banks,
        "ROW_WORDS=%d" % mem.row_words,
        "ROW_HIT=%d" % mem.row_hit,
        "ROW_MISS=%d" % mem.row_miss,
        "ROW_BUF=%d" % mem.row_buf,
        "CLOCK_MHZ=%d" % args.clock_mhz,
        "DBUF=%d" % dbuf,
        "PYTHON=%s" % args.python,
    ]

    if args.clean_between:
        run_cmd(["make", "clean"], args.rtl_dir)

    stdout, stderr, quoted = run_cmd(make_cmd, args.rtl_dir)
    row = parse_sv_csv(stdout)
    row["repeat"] = str(repeat)
    row["array"] = cfg.label
    row["shape"] = str(shape)
    row["mem_cfg"] = str(mem)
    row["gpu_target_gops"] = "%.6f" % float(args.gpu_target_gops)
    row["command"] = quoted
    return row


def numeric(row, key, default=0.0):
    try:
        return float(row.get(key, default))
    except (TypeError, ValueError):
        return default


def summarize_rows(rows):
    # Add a few derived convenience metrics in Python too, in case the RTL row changes.
    for row in rows:
        peak = numeric(row, "peak_gops")
        eff = numeric(row, "effective_gops")
        comp = numeric(row, "compute_gops")
        cycles = numeric(row, "cycles")
        cc = numeric(row, "compute_cycles")
        row["effective_vs_peak"] = "%.6f" % ((eff / peak) if peak else 0.0)
        row["compute_vs_peak"] = "%.6f" % ((comp / peak) if peak else 0.0)
        row["noncompute_cycles"] = "%.0f" % max(0.0, cycles - cc)
        target = numeric(row, "gpu_target_gops", 0.0)
        if target:
            row["effective_vs_gpu_target"] = "%.6f" % (eff / target)
            row["compute_vs_gpu_target"] = "%.6f" % (comp / target)
            row["peak_vs_gpu_target"] = "%.6f" % (peak / target)


def write_csv(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    preferred = [
        "repeat", "test_kind", "array", "shape", "mem_cfg", "slot",
        "rows", "cols", "k_tile", "m", "n", "k", "double_buffer",
        "clock_mhz", "mem_read_lat", "mem_write_lat", "read_gap", "write_gap",
        "max_outstanding", "banks", "row_words", "row_hit", "row_miss", "row_buffer",
        "cycles", "compute_cycles", "noncompute_cycles", "memory_stall_cycles",
        "prefetch_cycles", "compute_wait_cycles", "mem_cycles",
        "reads", "writes", "mem_reads", "mem_writes", "bytes_read", "bytes_written", "modeled_bytes",
        "loaded_k_tiles", "output_tiles", "macs", "ops", "peak_macs_per_cycle", "peak_ops_per_cycle",
        "effective_macs_per_cycle", "effective_ops_per_cycle", "compute_macs_per_cycle", "compute_ops_per_cycle",
        "effective_gops", "compute_gops", "peak_gops", "gpu_target_gops",
        "effective_vs_peak", "compute_vs_peak", "effective_vs_gpu_target", "compute_vs_gpu_target", "peak_vs_gpu_target",
        "overall_pe_util", "compute_pe_util", "per_pe_effective_ops_per_cycle", "per_pe_compute_ops_per_cycle",
        "arithmetic_intensity", "mem_bytes_per_cycle", "mem_read_bytes_per_cycle", "mem_write_bytes_per_cycle",
        "memory_stall_frac", "compute_frac", "prefetch_frac", "compute_wait_frac", "command"
    ]
    keys = set()
    for row in rows:
        keys.update(row.keys())
    extra = sorted(keys - set(preferred))
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=preferred + extra)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def try_import_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        return plt
    except Exception as e:
        sys.stderr.write("Plotting skipped: could not import matplotlib (%s)\n" % e)
        return None


def group_key(row, keys):
    return tuple(row.get(k, "") for k in keys)


def plot_metric_vs_array(plt, rows, out_dir, metric, title, ylabel):
    # One bar per array for the largest shape under the first memory config, DBUF=1 where present.
    if not rows:
        return
    # Choose maximal ops shape to avoid tiny-matrix fill/drain distortion.
    max_ops = max(numeric(r, "ops") for r in rows)
    mem0 = rows[0].get("mem_cfg", "")
    filt = [r for r in rows if numeric(r, "ops") == max_ops and r.get("mem_cfg", "") == mem0]
    if any(r.get("double_buffer") == "1" for r in filt):
        filt = [r for r in filt if r.get("double_buffer") == "1"]
    if not filt:
        return
    labels = [r.get("array", "") for r in filt]
    values = [numeric(r, metric) for r in filt]
    plt.figure(figsize=(9, 5))
    plt.bar(range(len(labels)), values)
    plt.xticks(range(len(labels)), labels, rotation=30, ha="right")
    plt.ylabel(ylabel)
    plt.title(title)
    target = numeric(filt[0], "gpu_target_gops") if metric in ("effective_gops", "compute_gops", "peak_gops") else 0.0
    if target:
        plt.axhline(target, linestyle="--", linewidth=1, label="GPU target %.0f GOP/s" % target)
        plt.legend()
    plt.tight_layout()
    plt.savefig(str(out_dir / (metric + "_vs_array.png")), dpi=160)
    plt.close()


def plot_metric_vs_mem_latency(plt, rows, out_dir, metric, title, ylabel):
    # For each array, plot metric vs read latency on largest square-ish shape.
    if not rows:
        return
    shape0 = max(set(r.get("shape", "") for r in rows), key=lambda s: max([numeric(r, "ops") for r in rows if r.get("shape") == s] or [0]))
    arrays = sorted(set(r.get("array", "") for r in rows))
    plt.figure(figsize=(9, 5))
    for arr in arrays:
        pts = [r for r in rows if r.get("array") == arr and r.get("shape") == shape0 and r.get("double_buffer") == "1"]
        pts.sort(key=lambda r: numeric(r, "mem_read_lat"))
        if len(pts) < 2:
            continue
        x = [numeric(r, "mem_read_lat") for r in pts]
        y = [numeric(r, metric) for r in pts]
        plt.plot(x, y, marker="o", label=arr)
    plt.xlabel("Read latency (cycles)")
    plt.ylabel(ylabel)
    target = numeric(rows[0], "gpu_target_gops") if metric in ("effective_gops", "compute_gops", "peak_gops") else 0.0
    if target:
        plt.axhline(target, linestyle="--", linewidth=1, label="GPU target %.0f GOP/s" % target)
    plt.title(title)
    plt.legend()
    plt.tight_layout()
    plt.savefig(str(out_dir / (metric + "_vs_read_latency.png")), dpi=160)
    plt.close()


def plot_roofline_like(plt, rows, out_dir):
    if not rows:
        return
    plt.figure(figsize=(8, 5))
    for dbuf in sorted(set(r.get("double_buffer", "") for r in rows)):
        pts = [r for r in rows if r.get("double_buffer") == dbuf]
        x = [numeric(r, "arithmetic_intensity") for r in pts]
        y = [numeric(r, "effective_gops") for r in pts]
        plt.scatter(x, y, label="DBUF=%s" % dbuf)
    plt.xlabel("Arithmetic intensity (ops / modeled byte)")
    plt.ylabel("Effective GOP/s")
    plt.title("Roofline-style scatter: arithmetic intensity vs effective throughput")
    plt.legend()
    plt.tight_layout()
    plt.savefig(str(out_dir / "roofline_style_scatter.png"), dpi=160)
    plt.close()


def make_plots(rows, plot_dir):
    plot_dir.mkdir(parents=True, exist_ok=True)
    plt = try_import_matplotlib()
    if plt is None:
        return
    plot_metric_vs_array(plt, rows, plot_dir, "effective_gops",
                         "End-to-end throughput by systolic-array shape", "Effective GOP/s")
    plot_metric_vs_array(plt, rows, plot_dir, "compute_gops",
                         "Compute-only throughput by systolic-array shape", "Compute-only GOP/s")
    plot_metric_vs_array(plt, rows, plot_dir, "peak_gops",
                         "Ideal peak throughput by systolic-array shape", "Peak GOP/s")
    plot_metric_vs_array(plt, rows, plot_dir, "compute_pe_util",
                         "Compute-phase PE utilization by systolic-array shape", "Compute PE utilization")
    plot_metric_vs_array(plt, rows, plot_dir, "per_pe_compute_ops_per_cycle",
                         "Per-PE compute throughput", "Ops / cycle / PE")
    plot_metric_vs_mem_latency(plt, rows, plot_dir, "effective_gops",
                               "Memory sensitivity: effective throughput vs read latency", "Effective GOP/s")
    plot_metric_vs_mem_latency(plt, rows, plot_dir, "memory_stall_frac",
                               "Memory sensitivity: stall fraction vs read latency", "Memory stall fraction")
    plot_roofline_like(plt, rows, plot_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl-dir", type=pathlib.Path, default=RTL_DIR)
    parser.add_argument("--out", type=pathlib.Path, default=RTL_DIR / "build" / "fpga_sweep.csv")
    parser.add_argument("--plot-dir", type=pathlib.Path, default=RTL_DIR / "build" / "plots")
    parser.add_argument("--array-preset", default="gpu_scale",
                        help="Array sweep preset: small, large, gpu_scale, or huge. Ignored if --arrays is supplied.")
    parser.add_argument("--arrays", default=None,
                        help="Comma-separated ROWSxCOLSxKTILE list. Overrides --array-preset.")
    parser.add_argument("--shapes", default="64x64x64,128x128x128,256x256x256,1024x1024x1024,128x1024x256,1024x128x256")
    parser.add_argument("--mem", default=DEFAULT_MEM_PROFILE_ORDER)
    parser.add_argument("--double-buffer", default="1")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--clock-mhz", type=int, default=1000)
    parser.add_argument("--gpu-target-gops", type=float, default=1000.0,
                        help="Reference GPU throughput line for plots/ratios. Default: 1000 GOP/s.")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--clean-between", action="store_true")
    parser.add_argument("--no-plots", action="store_true")
    args = parser.parse_args()

    args.rtl_dir = args.rtl_dir.resolve()
    array_spec = args.arrays if args.arrays else array_preset_string(args.array_preset)
    arrays = parse_array_cfgs(array_spec)
    shapes = parse_shapes(args.shapes)
    mem_cfgs = parse_mem_cfgs(args.mem)
    dbufs = parse_int_list(args.double_buffer)

    print("Array sweep: %s" % ", ".join(str(a) for a in arrays))

    rows = []
    total = args.repeats * len(arrays) * len(shapes) * len(mem_cfgs) * len(dbufs)
    idx = 0
    for repeat in range(args.repeats):
        for cfg in arrays:
            for shape in shapes:
                for mem in mem_cfgs:
                    for dbuf in dbufs:
                        idx += 1
                        print("[%d/%d] array=%s shape=%s mem=%s dbuf=%d" % (idx, total, cfg, shape, mem, dbuf))
                        row = run_case(args, cfg, shape, mem, dbuf, repeat)
                        rows.append(row)
                        print("  effective_gops=%s compute_gops=%s pe_util=%s cycles=%s" % (
                            row.get("effective_gops", "?"), row.get("compute_gops", "?"),
                            row.get("compute_pe_util", "?"), row.get("cycles", "?")))

    summarize_rows(rows)
    write_csv(args.out, rows)
    print("Wrote %d rows to %s" % (len(rows), args.out))

    if not args.no_plots:
        make_plots(rows, args.plot_dir)
        print("Wrote plots to %s" % args.plot_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
