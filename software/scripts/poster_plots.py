#!/usr/bin/env python3
from __future__ import print_function

import argparse
import csv
import os
import pathlib
import subprocess
import sys
import tempfile
from datetime import datetime

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

PALETTE = {
    "deep_blue":   "#1F3A5F",
    "teal":        "#2E8B7E",
    "amber":       "#D49A36",
    "coral":       "#C7522A",
    "purple":      "#6A4C93",
    "rose":        "#A6325F",
    "olive":       "#5A7F2E",
    "slate":       "#4A5568",
    "soft_gray":   "#9CA3AF",
    "ink":         "#1A1F2E",
    "paper":       "#FBFAF7",
    "grid":        "#E5E7EB",
}

# Color mapping for consistent series across figures
ARRAY_COLORS = {
    "4x4x8":       PALETTE["soft_gray"],
    "8x8x16":      PALETTE["amber"],
    "16x16x32":    PALETTE["teal"],
    "32x32x64":    PALETTE["coral"],
    "64x64x128":   PALETTE["deep_blue"],
    "128x128x256": PALETTE["purple"],
}

DATAFLOW_COLORS = {
    "OS": PALETTE["coral"],
    "WS": PALETTE["teal"],
    "IS": PALETTE["purple"],
}

MEM_COLORS = {
    "L1_hit":    PALETTE["teal"],
    "L2_hit":    PALETTE["amber"],
    "LLC_hit":   PALETTE["coral"],
    "DRAM_like": PALETTE["deep_blue"],
    "RTX2080_GDDR6_448GBps": PALETTE["rose"],
    "HBM_like_512GBps_at_1GHz": PALETTE["purple"],
    "HBM_like_1TBps_at_1GHz": PALETTE["olive"],
}

# Typography — research-paper feel: serif title + clean sans body
FONT_TITLE = {"family": "DejaVu Serif", "size": 13, "weight": "bold"}
FONT_SUBTITLE = {"family": "DejaVu Sans", "size": 9.5,
                 "color": PALETTE["slate"], "style": "italic"}
FONT_AXIS = {"family": "DejaVu Sans", "size": 10}
FONT_TICK = {"family": "DejaVu Sans", "size": 9}
FONT_LEGEND = {"family": "DejaVu Sans", "size": 8.5}
FONT_ANNOT = {"family": "DejaVu Sans", "size": 8.5,
              "color": PALETTE["slate"], "style": "italic"}


def style_axes(ax, title=None, subtitle=None, xlabel=None, ylabel=None,
               x_log=False, y_log=False):
    """Apply consistent visual styling to an Axes object."""
    ax.set_facecolor(PALETTE["paper"])
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    for spine in ("left", "bottom"):
        ax.spines[spine].set_color(PALETTE["slate"])
        ax.spines[spine].set_linewidth(0.7)
    ax.tick_params(axis="both", colors=PALETTE["slate"], labelsize=9,
                   length=3, width=0.7)
    ax.grid(True, which="major", color=PALETTE["grid"], linewidth=0.6,
            zorder=0)
    if x_log:
        ax.set_xscale("log")
    if y_log:
        ax.set_yscale("log")
    # Place title on a higher row, subtitle below it but above the axes top.
    if title and subtitle:
        ax.text(0.0, 1.14, title, transform=ax.transAxes,
                fontdict=FONT_TITLE, color=PALETTE["ink"], va="bottom")
        ax.text(0.0, 1.04, subtitle, transform=ax.transAxes,
                fontdict=FONT_SUBTITLE, va="bottom")
    elif title:
        ax.text(0.0, 1.04, title, transform=ax.transAxes,
                fontdict=FONT_TITLE, color=PALETTE["ink"], va="bottom")
    if xlabel:
        ax.set_xlabel(xlabel, fontdict=FONT_AXIS, color=PALETTE["ink"],
                      labelpad=6)
    if ylabel:
        ax.set_ylabel(ylabel, fontdict=FONT_AXIS, color=PALETTE["ink"],
                      labelpad=8)


def attach_legend(ax, *args, **kwargs):
    leg = ax.legend(*args, frameon=False, fontsize=FONT_LEGEND["size"],
                    **kwargs)
    if leg is not None:
        for text in leg.get_texts():
            text.set_color(PALETTE["ink"])
    return leg

def run_estimator(estimator_path, args_list):
    """Invoke estimate_perf.py and return parsed CSV rows."""
    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False, mode="w") as tmp:
        tmp_path = tmp.name
    cmd = [sys.executable, estimator_path] + args_list + [
        "--out", tmp_path, "--quiet"]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit("estimator failed: %s" % " ".join(cmd))
    rows = []
    with open(tmp_path) as f:
        for r in csv.DictReader(f):
            rows.append(r)
    os.unlink(tmp_path)
    return rows


def fnum(row, key, default=0.0):
    try:
        return float(row.get(key, default))
    except (TypeError, ValueError):
        return default


def _mem_pretty(mem_key):
    return {
        "l1":  "L1-class on-chip buffer",
        "l2":  "L2-class on-chip buffer",
        "llc": "BRAM/LLC-class staging buffer",
        "dram": "DRAM-class off-chip memory",
        "rtx2080": "RTX 2080 GDDR6 memory",
        "gpu_gddr6": "RTX 2080 GDDR6 memory",
        "hbm": "HBM-class high-bandwidth memory",
        "hbm_high": "high-end HBM memory",
    }.get(mem_key, mem_key)

def fig01_throughput_vs_square_size(estimator, plot_dir, clock_mhz, default_mem):
    arrays = "4x4x8,8x8x16,16x16x32,32x32x64,64x64x128"
    sizes = [128, 256, 512, 1024, 1536]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)
    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",            # WS = best general-purpose
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5.6), dpi=150)
    fig.subplots_adjust(top=0.82)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="GEMM throughput vs square matrix size",
        subtitle=("Tiled systolic array, weight-stationary, double-buffered, "
                  "%s @ %d MHz" % (_mem_pretty(default_mem), clock_mhz)),
        xlabel="Matrix size N (square N×N×N GEMM)",
        ylabel="Throughput (GFLOP/s)",
    )

    array_labels = arrays.split(",")
    for arr_label in array_labels:
        sub = [r for r in rows if r["array"] == arr_label]
        sub.sort(key=lambda r: int(r["m"]))
        xs = [int(r["m"]) for r in sub]
        ys = [fnum(r, "effective_gops") for r in sub]
        peak = fnum(sub[-1], "peak_gops")
        rows_ = int(arr_label.split("x")[0])
        cols_ = int(arr_label.split("x")[1])
        pretty = "%d×%d array  (%d PEs, peak %.0f GFLOP/s)" % (
            rows_, cols_, rows_ * cols_, peak)
        ax.plot(xs, ys, marker="o", markersize=6, linewidth=2.0,
                color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                label=pretty, markerfacecolor="white",
                markeredgewidth=1.6)

    ax.set_xticks(sizes)
    ax.set_xticklabels(["%d" % s for s in sizes])
    ax.set_xlim(min(sizes) - 50, max(sizes) + 50)
    attach_legend(ax, loc="upper left", title="Array configuration",
                  title_fontsize=9)

    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig01_throughput_vs_square_size.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig02_throughput_vs_rectangular_shape(estimator, plot_dir, clock_mhz, default_mem):
    # A representative collection of GEMM shapes that appear in real workloads:
    # square (matrix algebra), tall-skinny (batched MLP), wide (attention proj),
    # large-K (reduction-dominant), and tiny-K (low-reuse pathological case).
    shape_groups = [
        ("Square 256",       (256, 256, 256),    "balanced"),
        ("Square 1024",      (1024, 1024, 1024), "balanced"),
        ("Tall (M-dom)",     (2048, 256, 512),   "batch×features"),
        ("Wide (N-dom)",     (256, 2048, 512),   "features×batch"),
        ("Deep K",           (256, 256, 4096),   "deep reduction"),
        ("Shallow K",        (1024, 1024, 64),   "low reuse"),
        ("Attention QKV",    (1024, 768, 768),   "transformer"),
        ("MLP layer",        (512, 4096, 1024),  "ffn-style"),
    ]
    shapes_csv = ",".join("%dx%dx%d" % s[1] for s in shape_groups)

    arrays = "8x8x16,16x16x32,32x32x64"

    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes_csv,
        "--dataflows", "ws",
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(11, 5.9), dpi=150)
    fig.subplots_adjust(top=0.82)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="GEMM throughput across realistic workload shapes",
        subtitle=("Effective throughput on representative dense, batched, and "
                  "attention-style shapes (M×N×K)"),
        xlabel="Shape category",
        ylabel="Throughput (GFLOP/s)",
    )

    array_labels = arrays.split(",")
    n_arrays = len(array_labels)
    n_shapes = len(shape_groups)
    bar_w = 0.78 / n_arrays
    x_base = list(range(n_shapes))

    for ai, arr_label in enumerate(array_labels):
        ys = []
        for shape_label, dims, _ in shape_groups:
            shape_str = "%dx%dx%d" % dims
            sub = [r for r in rows
                   if r["array"] == arr_label and r["shape"] == shape_str]
            ys.append(fnum(sub[0], "effective_gops") if sub else 0.0)
        xs = [x + (ai - (n_arrays - 1) / 2.0) * bar_w for x in x_base]
        rows_ = int(arr_label.split("x")[0])
        cols_ = int(arr_label.split("x")[1])
        ax.bar(xs, ys, width=bar_w * 0.92,
               color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
               edgecolor=PALETTE["ink"], linewidth=0.5,
               label="%d×%d array" % (rows_, cols_))

    ax.set_xticks(x_base)
    short_labels = ["%s\n(%d×%d×%d)" % (s[0], s[1][0], s[1][1], s[1][2])
                    for s in shape_groups]
    ax.set_xticklabels(short_labels, fontsize=8.5)
    attach_legend(ax, loc="upper left", title="Array configuration",
                  title_fontsize=9, ncol=3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig02_throughput_vs_rectangular_shape.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig03_dataflow_comparison(estimator, plot_dir, clock_mhz, default_mem):
    sizes = [128, 256, 512, 1024, 1536]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)
    rows = run_estimator(estimator, [
        "--arrays", "32x32x16",
        "--shapes", shapes,
        "--dataflows", "os,ws,ns",
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="Dataflow strategy: output- vs weight- vs input-stationary",
        subtitle=("Same 32×32 array; WS/IS skip one operand reload per inner "
                  "tile and overlap exactly on square shapes"),
        xlabel="Square matrix size N",
        ylabel="Throughput (GFLOP/s)",
    )

    for df_label in ("OS", "WS", "IS"):
        sub = [r for r in rows if r["dataflow"] == df_label]
        sub.sort(key=lambda r: int(r["m"]))
        xs = [int(r["m"]) for r in sub]
        ys = [fnum(r, "effective_gops") for r in sub]
        long_label = {
            "OS": "Output-stationary  (no reuse)",
            "WS": "Weight-stationary  (B resident in PEs)",
            "IS": "Input-stationary  (A resident in PEs)",
        }[df_label]
        # IS plotted slightly thinner over WS to expose the overlap on square shapes.
        linestyle = "-"
        zorder = 3
        if df_label == "IS":
            linestyle = "--"
            zorder = 4
        ax.plot(xs, ys, marker="o", markersize=6, linewidth=2.0,
                linestyle=linestyle,
                color=DATAFLOW_COLORS[df_label], label=long_label,
                markerfacecolor="white", markeredgewidth=1.6,
                zorder=zorder)

    ax.set_xticks(sizes)
    ax.set_xticklabels(["%d" % s for s in sizes])
    attach_legend(ax, loc="upper left")
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig03_dataflow_comparison.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig04_double_buffer_impact(estimator, plot_dir, clock_mhz, default_mem):
    arrays = "8x8x16,16x16x32,32x32x64"
    sizes = [256, 512, 1024]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)

    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",
        "--mem", default_mem,
        "--double-buffer", "0,1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="Double buffering: prefetch the next K-tile during compute",
        subtitle=("Throughput uplift from overlapping memory loads with "
                  "systolic-array compute (%s @ %d MHz)" % (_mem_pretty(default_mem), clock_mhz)),
        xlabel="Array configuration · square matrix size",
        ylabel="Throughput (GFLOP/s)",
    )

    bar_w = 0.36
    array_labels = arrays.split(",")
    x_base = []
    x_lbls = []
    pos = 0
    for arr_label in array_labels:
        for size in sizes:
            x_base.append(pos)
            rows_ = int(arr_label.split("x")[0])
            cols_ = int(arr_label.split("x")[1])
            x_lbls.append("%dx%d\nN=%d" % (rows_, cols_, size))
            pos += 1
        pos += 0.5  # gap between array groups

    no_dbuf = []
    yes_dbuf = []
    for arr_label in array_labels:
        for size in sizes:
            shape_str = "%dx%dx%d" % (size, size, size)
            r0 = [r for r in rows
                  if r["array"] == arr_label and r["shape"] == shape_str
                  and r["double_buffer"] == "0"]
            r1 = [r for r in rows
                  if r["array"] == arr_label and r["shape"] == shape_str
                  and r["double_buffer"] == "1"]
            no_dbuf.append(fnum(r0[0], "effective_gops") if r0 else 0.0)
            yes_dbuf.append(fnum(r1[0], "effective_gops") if r1 else 0.0)

    xs0 = [x - bar_w / 2.0 for x in x_base]
    xs1 = [x + bar_w / 2.0 for x in x_base]
    ax.bar(xs0, no_dbuf, width=bar_w, color=PALETTE["soft_gray"],
           edgecolor=PALETTE["ink"], linewidth=0.5,
           label="Single-buffered  (DBUF = 0)")
    ax.bar(xs1, yes_dbuf, width=bar_w, color=PALETTE["teal"],
           edgecolor=PALETTE["ink"], linewidth=0.5,
           label="Double-buffered  (DBUF = 1)")

    # Annotate uplift on each pair
    for x, a, b in zip(x_base, no_dbuf, yes_dbuf):
        if a > 0 and b > a:
            uplift = (b - a) / a * 100.0
            ax.annotate("+%.0f%%" % uplift,
                        xy=(x, b), xytext=(0, 4),
                        textcoords="offset points",
                        ha="center", va="bottom",
                        fontsize=7.5, color=PALETTE["teal"], weight="bold")

    ax.set_xticks(x_base)
    ax.set_xticklabels(x_lbls, fontsize=8)
    attach_legend(ax, loc="upper left")
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig04_double_buffer_impact.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig05_memory_hierarchy_sensitivity(estimator, plot_dir, clock_mhz, default_mem):
    sizes = [128, 256, 512, 1024, 1536]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)

    rows = run_estimator(estimator, [
        "--arrays", "128x128x256",
        "--shapes", shapes,
        "--dataflows", "ws",
        "--mem", "l1,l2,llc,dram,rtx2080,hbm,hbm_high",
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="Memory tier sensitivity: throughput vs backing memory model",
        subtitle=("Same 128x128 array, weight-stationary, double-buffered. "),
        xlabel="Square matrix size N",
        ylabel="Throughput (GFLOP/s)",
    )

    mem_order = ["L1_hit", "L2_hit", "LLC_hit", "DRAM_like",
                 "RTX2080_GDDR6_448GBps",
                 "HBM_like_512GBps_at_1GHz", "HBM_like_1TBps_at_1GHz"]
    pretty = {
        "L1_hit":    "L1-class    (4-cycle hit)",
        "L2_hit":    "L2-class    (12-cycle hit)",
        "LLC_hit":   "LLC-class   (36-cycle hit)",
        "DRAM_like": "DRAM-class  (120/12 r-hit/r-miss)",
        "RTX2080_GDDR6_448GBps": "RTX 2080 GDDR6 (448 GB/s)",
        "HBM_like_512GBps_at_1GHz": "HBM-class   (~512 GB/s @ 1GHz)",
        "HBM_like_1TBps_at_1GHz":   "HBM-high    (~1 TB/s @ 1GHz)",
    }

    for mem_label in mem_order:
        sub = [r for r in rows if mem_label in r["mem_cfg"]]
        sub.sort(key=lambda r: int(r["m"]))
        xs = [int(r["m"]) for r in sub]
        ys = [fnum(r, "effective_gops") for r in sub]
        ax.plot(xs, ys, marker="o", markersize=6, linewidth=2.0,
                color=MEM_COLORS.get(mem_label, PALETTE["slate"]), label=pretty[mem_label],
                markerfacecolor="white", markeredgewidth=1.6)

    ax.set_xticks(sizes)
    ax.set_xticklabels(["%d" % s for s in sizes])
    attach_legend(ax, loc="upper left", title="Memory model",
                  title_fontsize=9)
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig05_memory_hierarchy_sensitivity.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig06_roofline(estimator, plot_dir, clock_mhz, default_mem):
    arrays = "8x8x16,16x16x32,32x32x64,64x64x128"
    sizes = [128, 256, 512, 1024, 1536, 2048]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)

    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5.5), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="Roofline analysis: arithmetic intensity vs achieved throughput",
        subtitle=("Each point = (array, GEMM size). Dotted lines = per-array "
                  "compute roofs; dashed line = active memory bandwidth roof"),
        xlabel="Arithmetic intensity (FLOP / byte)",
        ylabel="Achieved throughput (GFLOP/s)",
        x_log=True, y_log=True,
    )

    array_labels = arrays.split(",")
    for arr_label in array_labels:
        sub = [r for r in rows if r["array"] == arr_label]
        if not sub:
            continue
        rows_ = int(arr_label.split("x")[0])
        cols_ = int(arr_label.split("x")[1])
        xs = [fnum(r, "arithmetic_intensity") for r in sub]
        ys = [fnum(r, "effective_gops") for r in sub]
        ax.scatter(xs, ys, s=70, alpha=0.85,
                   color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                   edgecolors=PALETTE["ink"], linewidth=0.7,
                   label="%d×%d array  (peak %.0f GFLOP/s)" % (
                       rows_, cols_, fnum(sub[0], "peak_gops")), zorder=3)
        peak_g = fnum(sub[0], "peak_gops")
        ax.axhline(peak_g, color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                   linestyle=":", linewidth=1.0, alpha=0.6, zorder=1)

    # Bandwidth roof for the active memory tier.  HBM-aware estimators
    # emit mem_peak_GBps; fall back to the old latency/outstanding estimate
    # for compatibility with the original estimator.
    if rows and fnum(rows[0], "mem_peak_GBps") > 0.0:
        bw_gbs = fnum(rows[0], "mem_peak_GBps")
        mem_pretty = _mem_pretty(default_mem)
    else:
        bw_specs = {
            "l1":   (4,   64, "L1-class"),
            "l2":   (12,  32, "L2-class"),
            "llc":  (36,  16, "LLC-class"),
            "dram": (120,  8, "DRAM-class"),
            "hbm":  (160, 512, "HBM-class"),
            "hbm_high": (160, 1024, "HBM-high"),
        }
        base_lat, max_out, mem_pretty = bw_specs.get(default_mem, (120, 8, "DRAM-class"))
        words_per_cyc = max_out / float(base_lat)
        bw_gbs = words_per_cyc * 4 * clock_mhz * 1e6 / 1e9
    ai_range = [0.5, 200]
    bw_roof = [bw_gbs * x for x in ai_range]
    ax.plot(ai_range, bw_roof, color=PALETTE["rose"], linestyle="--",
            linewidth=1.4, alpha=0.85, zorder=2,
            label="%s bandwidth roof  (~%.1f GB/s)" % (mem_pretty, bw_gbs))

    attach_legend(ax, loc="lower right")
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig06_roofline.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig07_pe_utilization_vs_size(estimator, plot_dir, clock_mhz, default_mem):
    arrays = "8x8x16,16x16x32,32x32x64,64x64x128"
    # Hit small sizes hard to expose fill/drain inefficiency
    sizes = [16, 32, 64, 128, 256, 512, 1024, 2048]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)
    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="PE utilization vs matrix size — pipeline fill/drain efficiency",
        subtitle=("Wavefront fill/drain wastes K + R + C − 2 cycles per K-tile; "
                  "small matrices amplify the relative cost"),
        xlabel="Square matrix size N",
        ylabel="PE utilization (compute phase)",
        x_log=True,
    )

    array_labels = arrays.split(",")
    for arr_label in array_labels:
        sub = [r for r in rows if r["array"] == arr_label]
        sub.sort(key=lambda r: int(r["m"]))
        xs = [int(r["m"]) for r in sub]
        ys = [fnum(r, "compute_pe_util") * 100.0 for r in sub]
        rows_ = int(arr_label.split("x")[0])
        cols_ = int(arr_label.split("x")[1])
        ax.plot(xs, ys, marker="o", markersize=5, linewidth=1.8,
                color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                label="%d×%d array" % (rows_, cols_),
                markerfacecolor="white", markeredgewidth=1.4)

    ax.set_xticks(sizes)
    ax.set_xticklabels(["%d" % s for s in sizes], fontsize=8.5)
    ax.set_ylim(0, 105)
    ax.axhline(100, color=PALETTE["soft_gray"], linewidth=0.7,
               linestyle="--", zorder=1)
    ax.text(sizes[-1], 100, "  ideal", color=PALETTE["soft_gray"],
            fontsize=8, va="center", ha="left")
    attach_legend(ax, loc="lower right", title="Array configuration",
                  title_fontsize=9)
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig07_pe_utilization_vs_size.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig08_cycle_breakdown(estimator, plot_dir, clock_mhz, default_mem):
    arrays_short = ["8x8x16", "16x16x32", "32x32x64", "64x64x128"]
    arrays = ",".join(arrays_short)
    sizes = [256, 512, 1024]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)
    mems = ["l2", "llc", "dram"]
    pretty_mems = {"L2_hit": "L2", "LLC_hit": "LLC", "DRAM_like": "DRAM"}

    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",
        "--mem", ",".join(mems),
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(11, 5.5), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="Cycle decomposition: where is time actually spent?",
        subtitle=("Each bar sums to 1.0: compute + hidden prefetch (teal) vs. "
                  "memory stall (coral). Fixed N=1024, double-buffered."),
        xlabel="Array configuration · memory tier",
        ylabel="Cycle fraction",
    )

    target_size = 1024
    target_shape = "%dx%dx%d" % (target_size, target_size, target_size)

    bar_w = 0.7
    x_pos = []
    x_lbls = []
    pos = 0
    # compute_prefetch_y = compute_frac + prefetch_frac.
    # Under double buffering, prefetch happens *during* compute — they share
    # the same wall-clock slice. Together they represent "time doing useful work."
    # memory_stall_frac is the remaining fraction where the array is stalled
    # waiting for tile data. By construction in the estimator:
    #   compute_frac + prefetch_frac + memory_stall_frac == 1.0
    # so the two stacked bars always reach exactly 1.0.
    compute_prefetch_y = []
    stall_y = []
    for arr_label in arrays_short:
        for mem_label in ["L2_hit", "LLC_hit", "DRAM_like"]:
            sub = [r for r in rows
                   if r["array"] == arr_label
                   and r["shape"] == target_shape
                   and mem_label in r["mem_cfg"]]
            if not sub:
                compute_prefetch_y.append(0.0)
                stall_y.append(0.0)
            else:
                r = sub[0]
                compute_prefetch_y.append(fnum(r, "compute_frac")
                                          + fnum(r, "prefetch_frac"))
                stall_y.append(fnum(r, "memory_stall_frac"))
            x_pos.append(pos)
            rows_ = int(arr_label.split("x")[0])
            x_lbls.append("%d×%d\n%s" % (rows_, rows_, pretty_mems[mem_label]))
            pos += 1
        pos += 0.6  # array group gap

    ax.bar(x_pos, compute_prefetch_y, width=bar_w, color=PALETTE["teal"],
           edgecolor=PALETTE["ink"], linewidth=0.5,
           label="Compute  (incl. prefetch overlap)")
    ax.bar(x_pos, stall_y, width=bar_w, bottom=compute_prefetch_y,
           color=PALETTE["coral"], edgecolor=PALETTE["ink"], linewidth=0.5,
           label="Memory stall  (waiting for tile data)")

    ax.set_xticks(x_pos)
    ax.set_xticklabels(x_lbls, fontsize=8)
    ax.set_ylim(0, 1.05)
    ax.axhline(1.0, color=PALETTE["slate"], linewidth=0.6,
               linestyle="--", alpha=0.5, zorder=0)
    attach_legend(ax, loc="upper right")
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig08_cycle_breakdown.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig09_array_scaling(estimator, plot_dir, clock_mhz, default_mem):
    arrays_list = [
        ("4x4x8",     16),
        ("8x8x16",    64),
        ("16x16x32",  256),
        ("32x32x64",  1024),
        ("64x64x128", 4096),
    ]
    arrays = ",".join(a[0] for a in arrays_list)
    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", "1024x1024x1024",
        "--dataflows", "ws",
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5.2), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="Scaling with PE count: peak vs achieved throughput",
        subtitle=("Doubling each array dimension quadruples PEs; achieved "
                  "Backing memory: %s." % _mem_pretty(default_mem)),
        xlabel="Number of processing elements",
        ylabel="Throughput (GFLOP/s)",
        x_log=True, y_log=True,
    )

    pe_counts = []
    peak_y = []
    eff_y = []
    arr_labels = []
    for arr_label, pe_count in arrays_list:
        sub = [r for r in rows if r["array"] == arr_label]
        if not sub:
            continue
        pe_counts.append(pe_count)
        peak_y.append(fnum(sub[0], "peak_gops"))
        eff_y.append(fnum(sub[0], "effective_gops"))
        arr_labels.append(arr_label)

    ax.plot(pe_counts, peak_y, marker="o", linewidth=2.0, markersize=7,
            color=PALETTE["soft_gray"],
            label="Peak (ideal compute roof)",
            markerfacecolor="white", markeredgewidth=1.6)
    ax.plot(pe_counts, eff_y, marker="o", linewidth=2.0, markersize=7,
            color=PALETTE["deep_blue"],
            label="Achieved (%s, N=1024 GEMM)" % _mem_pretty(default_mem),
            markerfacecolor="white", markeredgewidth=1.6)

    # Annotate efficiency
    for x, peak, eff in zip(pe_counts, peak_y, eff_y):
        if peak > 0:
            efficiency = eff / peak * 100.0
            ax.annotate("%.0f%%" % efficiency,
                        xy=(x, eff), xytext=(0, -14),
                        textcoords="offset points",
                        ha="center", va="top",
                        fontsize=8, color=PALETTE["deep_blue"], weight="bold")

    ax.set_xticks(pe_counts)
    ax.set_xticklabels(["%d" % p for p in pe_counts])
    attach_legend(ax, loc="upper left")
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig09_array_scaling.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig10_comp_throughput_vs_square_size(estimator, plot_dir, clock_mhz, default_mem):
    arrays = "32x32x64,64x64x128,128x128x256,256x256x512"
    sizes = [32, 64, 128, 256, 512, 1024, 1536]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)
    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",            # WS = best general-purpose
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10, 5.6), dpi=150)
    fig.subplots_adjust(top=0.82)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="GEMM computational throughput vs square matrix size",
        subtitle=("Tiled systolic array, weight-stationary, double-buffered, "
                  "%s @ %d MHz" % (_mem_pretty(default_mem), clock_mhz)),
        xlabel="Matrix size N (square N×N×N GEMM)",
        ylabel="Compute Throughput (GFLOP/s)",
    )

    array_labels = arrays.split(",")
    for arr_label in array_labels:
        sub = [r for r in rows if r["array"] == arr_label]
        sub.sort(key=lambda r: int(r["m"]))
        xs = [int(r["m"]) for r in sub]
        ys = [fnum(r, "compute_gops") for r in sub]
        peak = fnum(sub[-1], "peak_gops")
        rows_ = int(arr_label.split("x")[0])
        cols_ = int(arr_label.split("x")[1])
        pretty = "%d×%d array  (%d PEs, peak %.0f GFLOP/s)" % (
            rows_, cols_, rows_ * cols_, peak)
        ax.plot(xs, ys, marker="o", markersize=6, linewidth=2.0,
                color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                label=pretty, markerfacecolor="white",
                markeredgewidth=1.6)

    ax.set_xticks(sizes)
    ax.set_xticklabels(["%d" % s for s in sizes])
    ax.set_xlim(min(sizes) - 50, max(sizes) + 50)
    attach_legend(ax, loc="upper left", title="Array configuration",
                  title_fontsize=9)

    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig10_comp_throughput_vs_square_size.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig11_comp_throughput_vs_rectangular_shape(estimator, plot_dir, clock_mhz, default_mem):
    # A representative collection of GEMM shapes that appear in real workloads:
    # square (matrix algebra), tall-skinny (batched MLP), wide (attention proj),
    # large-K (reduction-dominant), and tiny-K (low-reuse pathological case).
    shape_groups = [
        ("Square 256",       (256, 256, 256),    "balanced"),
        ("Square 1024",      (1024, 1024, 1024), "balanced"),
        ("Tall (M-dom)",     (2048, 256, 512),   "batch×features"),
        ("Wide (N-dom)",     (256, 2048, 512),   "features×batch"),
        ("Deep K",           (256, 256, 4096),   "deep reduction"),
        ("Shallow K",        (1024, 1024, 64),   "low reuse"),
        ("Attention QKV",    (1024, 768, 768),   "transformer"),
        ("MLP layer",        (512, 4096, 1024),  "ffn-style"),
    ]
    shapes_csv = ",".join("%dx%dx%d" % s[1] for s in shape_groups)

    arrays = "8x8x16,16x16x32,32x32x64,64x64x128,128x128x256"

    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes_csv,
        "--dataflows", "ws",
        "--mem", default_mem,
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(11, 5.9), dpi=150)
    fig.subplots_adjust(top=0.82)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="GEMM computational throughput across realistic workload shapes",
        subtitle=("Computational throughput on representative dense, batched, and "
                  "attention-style shapes (M×N×K)"),
        xlabel="Shape category",
        ylabel="Compute Throughput (GFLOP/s)",
    )

    array_labels = arrays.split(",")
    n_arrays = len(array_labels)
    n_shapes = len(shape_groups)
    bar_w = 0.78 / n_arrays
    x_base = list(range(n_shapes))

    for ai, arr_label in enumerate(array_labels):
        ys = []
        for shape_label, dims, _ in shape_groups:
            shape_str = "%dx%dx%d" % dims
            sub = [r for r in rows
                   if r["array"] == arr_label and r["shape"] == shape_str]
            ys.append(fnum(sub[0], "compute_gops") if sub else 0.0)
        xs = [x + (ai - (n_arrays - 1) / 2.0) * bar_w for x in x_base]
        rows_ = int(arr_label.split("x")[0])
        cols_ = int(arr_label.split("x")[1])
        ax.bar(xs, ys, width=bar_w * 0.92,
               color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
               edgecolor=PALETTE["ink"], linewidth=0.5,
               label="%d×%d array" % (rows_, cols_))

    ax.set_xticks(x_base)
    short_labels = ["%s\n(%d×%d×%d)" % (s[0], s[1][0], s[1][1], s[1][2])
                    for s in shape_groups]
    ax.set_xticklabels(short_labels, fontsize=8.5)
    attach_legend(ax, loc="upper left", title="Array configuration",
                  title_fontsize=9, ncol=3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig11_comp_throughput_vs_rectangular_shape.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig12_hbm_memory_sweep(estimator, plot_dir, clock_mhz, default_mem):
    """Dedicated memory-bandwidth sweep that includes HBM and HBM-high.

    This is the figure to use when arguing that the systolic fabric is good
    but bandwidth-starved under conventional cache/DRAM memory models.
    """
    arrays = "16x16x32,32x32x64,64x64x128,128x128x256"
    sizes = [256, 512, 1024, 1536]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)

    rows = run_estimator(estimator, [
        "--arrays", arrays,
        "--shapes", shapes,
        "--dataflows", "ws",
        "--mem", "l1,l2,llc,dram,rtx2080,hbm,hbm_high",
        "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz),
    ])

    fig, ax = plt.subplots(figsize=(10.8, 5.6), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    style_axes(
        ax,
        title="HBM sensitivity: memory bandwidth unlocks systolic-array throughput",
        subtitle=("Weight-stationary, double-buffered. HBM models expose that "
                  "larger arrays are bandwidth-starved under conventional memories."),
        xlabel="Memory model",
        ylabel="Throughput at N=1024 (GFLOP/s)",
        y_log=True,
    )

    mem_order = [
        ("L1_hit", "L1"),
        ("L2_hit", "L2"),
        ("LLC_hit", "LLC"),
        ("DRAM_like", "DRAM"),
        ("RTX2080_GDDR6_448GBps", "RTX 2080\nGDDR6"),
        ("HBM_like_512GBps_at_1GHz", "HBM"),
        ("HBM_like_1TBps_at_1GHz", "HBM-high"),
    ]
    target_shape = "1024x1024x1024"
    array_labels = arrays.split(",")
    n_arrays = len(array_labels)
    x_base = list(range(len(mem_order)))
    bar_w = 0.78 / n_arrays

    for ai, arr_label in enumerate(array_labels):
        ys = []
        for mem_label, _ in mem_order:
            sub = [r for r in rows
                   if r["array"] == arr_label
                   and r["shape"] == target_shape
                   and mem_label in r["mem_cfg"]]
            ys.append(fnum(sub[0], "effective_gops") if sub else 0.0)
        xs = [x + (ai - (n_arrays - 1) / 2.0) * bar_w for x in x_base]
        rdim = int(arr_label.split("x")[0])
        cdim = int(arr_label.split("x")[1])
        ax.bar(xs, ys, width=bar_w * 0.92,
               color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
               edgecolor=PALETTE["ink"], linewidth=0.5,
               label="%d×%d array" % (rdim, cdim))

    ax.set_xticks(x_base)
    ax.set_xticklabels([label for _, label in mem_order])
    attach_legend(ax, loc="upper left", title="Array configuration",
                  title_fontsize=9, ncol=2)
    fig.tight_layout()
    fig.savefig(str(plot_dir / "fig12_hbm_memory_sweep.png"),
                dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)

def fig_compound_panel(estimator, plot_dir, clock_mhz, default_mem):
    fig = plt.figure(figsize=(15, 11), dpi=150)
    fig.patch.set_facecolor(PALETTE["paper"])
    gs = fig.add_gridspec(2, 2, hspace=0.65, wspace=0.30,
                          left=0.06, right=0.98, top=0.86, bottom=0.07)

    fig.suptitle("Tiled systolic GEMM accelerator — system-level performance summary",
                 fontfamily="DejaVu Serif", fontsize=15, fontweight="bold",
                 color=PALETTE["ink"], y=0.965)
    fig.text(0.5, 0.935,
             "Analytical projection across array shapes, GEMM sizes, dataflows, and memory tiers",
             fontfamily="DejaVu Sans", fontsize=10, fontstyle="italic",
             color=PALETTE["slate"], ha="center")

    # ----- Panel A: throughput vs square size -----
    ax = fig.add_subplot(gs[0, 0])
    arrays = "4x4x8,8x8x16,16x16x32,32x32x64,64x64x128"
    sizes = [128, 256, 512, 1024, 1536]
    shapes = ",".join("%dx%dx%d" % (s, s, s) for s in sizes)
    rows = run_estimator(estimator, [
        "--arrays", arrays, "--shapes", shapes, "--dataflows", "ws",
        "--mem", default_mem, "--double-buffer", "1",
        "--clock-mhz", str(clock_mhz)])
    style_axes(ax,
               title="A · Throughput vs square matrix size",
               subtitle="WS dataflow, " + _mem_pretty(default_mem) + ", DBUF on",
               xlabel="Matrix size N", ylabel="GFLOP/s")
    for arr_label in arrays.split(","):
        sub = sorted([r for r in rows if r["array"] == arr_label],
                     key=lambda r: int(r["m"]))
        rows_ = int(arr_label.split("x")[0])
        ax.plot([int(r["m"]) for r in sub],
                [fnum(r, "effective_gops") for r in sub],
                marker="o", markersize=5, linewidth=1.8,
                color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                label="%d×%d" % (rows_, rows_),
                markerfacecolor="white", markeredgewidth=1.4)
    ax.set_xticks(sizes)
    attach_legend(ax, loc="upper left", title="Array",
                  title_fontsize=8.5, ncol=2)

    # ----- Panel B: dataflow comparison -----
    ax = fig.add_subplot(gs[0, 1])
    rows = run_estimator(estimator, [
        "--arrays", "16x16x32", "--shapes", shapes,
        "--dataflows", "os,ws,ns", "--mem", default_mem,
        "--double-buffer", "1", "--clock-mhz", str(clock_mhz)])
    style_axes(ax,
               title="B · Dataflow comparison (16×16 array)",
               subtitle="WS / IS reuse a stationary operand across tiles; OS reuses neither",
               xlabel="Matrix size N", ylabel="GFLOP/s")
    for df_label in ("OS", "WS", "IS"):
        sub = sorted([r for r in rows if r["dataflow"] == df_label],
                     key=lambda r: int(r["m"]))
        ax.plot([int(r["m"]) for r in sub],
                [fnum(r, "effective_gops") for r in sub],
                marker="o", markersize=5, linewidth=1.8,
                color=DATAFLOW_COLORS[df_label], label=df_label,
                markerfacecolor="white", markeredgewidth=1.4)
    ax.set_xticks(sizes)
    attach_legend(ax, loc="upper left", title="Dataflow",
                  title_fontsize=8.5)

    # ----- Panel C: roofline -----
    ax = fig.add_subplot(gs[1, 0])
    rs_arrays = "8x8x16,16x16x32,32x32x64,64x64x128"
    rs_sizes = [128, 256, 512, 1024, 1536, 2048]
    rs_shapes = ",".join("%dx%dx%d" % (s, s, s) for s in rs_sizes)
    rows = run_estimator(estimator, [
        "--arrays", rs_arrays, "--shapes", rs_shapes,
        "--dataflows", "ws", "--mem", default_mem,
        "--double-buffer", "1", "--clock-mhz", str(clock_mhz)])
    style_axes(ax,
               title="C · Roofline: arithmetic intensity vs throughput",
               subtitle="Each cluster of points = one array; the roof crosses shape regimes",
               xlabel="Arithmetic intensity (FLOP/byte)", ylabel="GFLOP/s",
               x_log=True, y_log=True)
    for arr_label in rs_arrays.split(","):
        sub = [r for r in rows if r["array"] == arr_label]
        if not sub:
            continue
        rows_ = int(arr_label.split("x")[0])
        ax.scatter([fnum(r, "arithmetic_intensity") for r in sub],
                   [fnum(r, "effective_gops") for r in sub],
                   s=55, alpha=0.85,
                   color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                   edgecolors=PALETTE["ink"], linewidth=0.6,
                   label="%d×%d" % (rows_, rows_), zorder=3)
        peak_g = fnum(sub[0], "peak_gops")
        ax.axhline(peak_g, color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                   linestyle=":", linewidth=0.9, alpha=0.5, zorder=1)
    # Bandwidth roof from the active memory tier.
    if rows and fnum(rows[0], "mem_peak_GBps") > 0.0:
        bw_gbs = fnum(rows[0], "mem_peak_GBps")
        mem_short = default_mem.upper()
    else:
        bw_specs = {"l1": (4, 64, "L1"), "l2": (12, 32, "L2"),
                    "llc": (36, 16, "LLC"), "dram": (120, 8, "DRAM"),
                    "hbm": (160, 512, "HBM"), "hbm_high": (160, 1024, "HBM-high")}
        base_lat, max_out, mem_short = bw_specs.get(default_mem, (120, 8, "DRAM"))
        words_per_cyc = max_out / float(base_lat)
        bw_gbs = words_per_cyc * 4 * clock_mhz * 1e6 / 1e9
    ai_range = [0.5, 200]
    ax.plot(ai_range, [bw_gbs * x for x in ai_range],
            color=PALETTE["rose"], linestyle="--", linewidth=1.3,
            alpha=0.85, zorder=2,
            label="%s BW (~%.1f GB/s)" % (mem_short, bw_gbs))
    attach_legend(ax, loc="lower right", ncol=2)

    # ----- Panel D: PE utilization vs size -----
    ax = fig.add_subplot(gs[1, 1])
    util_sizes = [16, 32, 64, 128, 256, 512, 1024, 2048]
    util_shapes = ",".join("%dx%dx%d" % (s, s, s) for s in util_sizes)
    rows = run_estimator(estimator, [
        "--arrays", rs_arrays, "--shapes", util_shapes,
        "--dataflows", "ws", "--mem", default_mem,
        "--double-buffer", "1", "--clock-mhz", str(clock_mhz)])
    style_axes(ax,
               title="D · PE utilization — fill/drain efficiency",
               subtitle="Small matrices pay relatively more for wavefront fill+drain",
               xlabel="Matrix size N", ylabel="PE utilization (%)",
               x_log=True)
    for arr_label in rs_arrays.split(","):
        sub = sorted([r for r in rows if r["array"] == arr_label],
                     key=lambda r: int(r["m"]))
        rows_ = int(arr_label.split("x")[0])
        ax.plot([int(r["m"]) for r in sub],
                [fnum(r, "compute_pe_util") * 100.0 for r in sub],
                marker="o", markersize=4, linewidth=1.6,
                color=ARRAY_COLORS.get(arr_label, PALETTE["slate"]),
                label="%d×%d" % (rows_, rows_),
                markerfacecolor="white", markeredgewidth=1.2)
    ax.axhline(100, color=PALETTE["soft_gray"], linewidth=0.7,
               linestyle="--", zorder=1)
    ax.set_xticks(util_sizes)
    ax.set_xticklabels(["%d" % s for s in util_sizes], fontsize=8)
    ax.set_ylim(0, 110)
    attach_legend(ax, loc="lower right", title="Array",
                  title_fontsize=8.5, ncol=2)

    fig.savefig(str(plot_dir / "poster_panel_compound.png"),
                dpi=200, facecolor=fig.get_facecolor())
    plt.close(fig)

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--estimator", default=None,
                   help="Path to estimate_perf.py (auto-detected if alongside this script)")
    p.add_argument("--plot-dir", default="poster_figures",
                   help="Output directory for PNGs.")
    p.add_argument("--clock-mhz", type=int, default=200,
                   help="Clock frequency for FPGA scaling (default"
                        "realistic for Artix-7).")
    p.add_argument("--default-mem", default="l1",
                   choices=["l1", "l2", "llc", "dram", "rtx2080", "gpu_gddr6", "hbm", "hbm_high"],
                   help="Default memory model used in figures that don't "
                        "explicitly sweep memory tier. L1 models a fully-"
                        "pipelined on-chip BRAM streaming buffer; LLC and "
                        "DRAM model progressively further memory tiers.")
    args = p.parse_args()

    here = pathlib.Path(__file__).resolve().parent
    if args.estimator is None:
        for cand in (here / "estimate_perf.py", here.parent / "estimate_perf.py",
                         here / "estimate_perf.py", here.parent / "estimate_perf.py"):
            if cand.exists():
                args.estimator = str(cand)
                break
        if args.estimator is None:
            sys.exit("Could not find estimate_perf.py; pass --estimator")

    plot_dir = pathlib.Path(args.plot_dir)
    plot_dir.mkdir(parents=True, exist_ok=True)

    figures = [
        ("fig01_throughput_vs_square_size",             fig01_throughput_vs_square_size),
        ("fig02_throughput_vs_rectangular_shape",       fig02_throughput_vs_rectangular_shape),
        ("fig03_dataflow_comparison",                   fig03_dataflow_comparison),
        ("fig04_double_buffer_impact",                  fig04_double_buffer_impact),
        ("fig05_memory_hierarchy_sensitivity",          fig05_memory_hierarchy_sensitivity),
        ("fig06_roofline",                              fig06_roofline),
        ("fig07_pe_utilization_vs_size",                fig07_pe_utilization_vs_size),
        ("fig08_cycle_breakdown",                       fig08_cycle_breakdown),
        ("fig09_array_scaling",                         fig09_array_scaling),
        ("fig10_comp_throughput_vs_square_size",        fig10_comp_throughput_vs_square_size),
        ("fig11_comp_throughput_vs_rectangular_shape",  fig11_comp_throughput_vs_rectangular_shape),
        ("fig12_hbm_memory_sweep",                      fig12_hbm_memory_sweep),
        ("poster_panel_compound",                       fig_compound_panel),
    ]
    for name, fn in figures:
        print("Rendering %s ..." % name)
        fn(args.estimator, plot_dir, args.clock_mhz, args.default_mem)

    print("\nWrote %d figures to %s" % (len(figures), plot_dir))
    for f in sorted(os.listdir(str(plot_dir))):
        size = os.path.getsize(str(plot_dir / f)) / 1024.0
        print("  %-50s  %6.1f KB" % (f, size))


if __name__ == "__main__":
    main()
