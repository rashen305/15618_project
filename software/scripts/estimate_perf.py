#!/usr/bin/env python3
from __future__ import print_function

import argparse
import csv
import math
import os
import pathlib
import sys
from datetime import datetime

class MemCfg(object):
    def __init__(self, read_lat, write_lat, read_gap=0, write_gap=0,
                 max_out=16, banks=4, row_words=1024, row_hit=12,
                 row_miss=28, row_buf=1, words_per_cycle=1.0, label=None,
                 fixed_peak_gbps=None):
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
        self.words_per_cycle = float(words_per_cycle)
        self.label = label
        # Optional fixed external-memory bandwidth, useful for a real GPU
        # memory reference whose GB/s should not scale with our accelerator clock.
        self.fixed_peak_gbps = None if fixed_peak_gbps is None else float(fixed_peak_gbps)

    def raw(self):
        return "%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%g" % (
            self.read_lat, self.write_lat, self.read_gap, self.write_gap,
            self.max_out, self.banks, self.row_words, self.row_hit,
            self.row_miss, self.row_buf, self.words_per_cycle)

    def __repr__(self):
        if self.label:
            return "%s=%s" % (self.label, self.raw())
        return self.raw()


CACHE_MEM_PROFILES = {
    "l1":   MemCfg(4,   1, 0, 0, 64, 16,  64, 1,  0, 0,   1.0, "L1_hit"),
    "l2":   MemCfg(12,  4, 0, 0, 32,  8, 128, 1,  0, 0,   1.0, "L2_hit"),
    "llc":  MemCfg(36, 12, 1, 1, 16,  4, 512, 1,  0, 0,   1.0, "LLC_hit"),
    "dram": MemCfg(120, 60, 2, 2, 8, 4, 1024, 12, 60, 1,  1.0, "DRAM_like"),

    # HBM-like architectural projections. These model the key missing system
    # resource for a large systolic array: many banks/channels and a wide
    # operand-delivery path. At 1 GHz, 128 32-bit words/cycle is ~512 GB/s;
    # 256 words/cycle is ~1 TB/s.
    "hbm":      MemCfg(160, 80, 0, 0, 512, 32, 2048, 8, 40, 1, 128.0, "HBM_like_512GBps_at_1GHz"),
    "hbm_high": MemCfg(160, 80, 0, 0, 1024, 64, 2048, 8, 40, 1, 256.0, "HBM_like_1TBps_at_1GHz"),

    # NVIDIA GeForce RTX 2080 memory reference from the tested GPU: 8 GB
    # GDDR6, 256-bit bus, 448 GB/s.  Latency values are approximate; the
    # important modeled quantity is fixed_peak_gbps=448.0.
    "rtx2080": MemCfg(140, 70, 0, 0, 512, 16, 1024, 8, 50, 1, 112.0,
                       "RTX2080_GDDR6_448GBps", fixed_peak_gbps=448.0),
    "gpu_gddr6": MemCfg(140, 70, 0, 0, 512, 16, 1024, 8, 50, 1, 112.0,
                         "RTX2080_GDDR6_448GBps", fixed_peak_gbps=448.0),
}

def split_list(value):
    if value is None:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


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


DATAFLOW_MODE = {"os": 0, "ws": 1, "ns": 2}
DATAFLOW_LABEL = {0: "OS", 1: "WS", 2: "NS"}


def parse_arrays(value):
    out = []
    for item in split_list(value):
        label = None
        if "=" in item:
            label, item = item.split("=", 1)
        parts = item.lower().split("x")
        if len(parts) != 3:
            raise SystemExit("Invalid array config %r" % item)
        out.append(ArrayCfg(int(parts[0]), int(parts[1]), int(parts[2]), label))
    return out


def parse_shapes(value):
    out = []
    for item in split_list(value):
        parts = item.lower().split("x")
        if len(parts) != 3:
            raise SystemExit("Invalid shape %r" % item)
        out.append(Shape(int(parts[0]), int(parts[1]), int(parts[2])))
    return out


def parse_dataflows(value):
    out = []
    for item in split_list(value):
        key = item.lower()
        if key in DATAFLOW_MODE:
            out.append(DATAFLOW_MODE[key])
        elif key.isdigit():
            out.append(int(key))
        else:
            raise SystemExit("Invalid dataflow %r" % item)
    return out


def parse_mem(value):
    out = []
    for item in split_list(value):
        label = None
        raw = item
        if "=" in item:
            label, raw = item.split("=", 1)
        key = raw.lower()
        if key in CACHE_MEM_PROFILES:
            prof = CACHE_MEM_PROFILES[key]
            out.append(MemCfg(prof.read_lat, prof.write_lat, prof.read_gap,
                              prof.write_gap, prof.max_out, prof.banks,
                              prof.row_words, prof.row_hit, prof.row_miss,
                              prof.row_buf, prof.words_per_cycle,
                              label or prof.label, prof.fixed_peak_gbps))
            continue
        parts = [int(p) for p in raw.split(":")]
        if len(parts) == 2:
            out.append(MemCfg(parts[0], parts[1], label=label))
        elif len(parts) == 4:
            out.append(MemCfg(parts[0], parts[1], parts[2], parts[3],
                              label=label))
        elif len(parts) == 10:
            out.append(MemCfg(parts[0], parts[1], parts[2], parts[3],
                              parts[4], parts[5], parts[6], parts[7],
                              parts[8], parts[9], 1.0, label=label))
        elif len(parts) == 11:
            out.append(MemCfg(parts[0], parts[1], parts[2], parts[3],
                              parts[4], parts[5], parts[6], parts[7],
                              parts[8], parts[9], parts[10], label=label))
        else:
            raise SystemExit("Invalid memory spec %r" % item)
    return out


def parse_int_list(value):
    return [int(v) for v in split_list(value)]

def ceil_div(a, b):
    return (a + b - 1) // b


def expected_per_request_latency(mem, is_write):
    """Effective per-request latency when issued back-to-back at steady state,
    accounting for max-outstanding pipelining and accept gaps. This mirrors
    the way main_memory_model.sv allocates pipe slots: any number of in-flight
    requests up to MAX_OUTSTANDING amortizes the base latency over the gap.
    """
    base = mem.write_lat if is_write else mem.read_lat
    gap = mem.write_gap if is_write else mem.read_gap

    # Without row-buffer modelling, the fully pipelined per-request cost is
    #     ceil(base / max_out) + gap + 1  (the +1 is the response handshake).
    # The min ensures gap dominates when bandwidth is gap-limited.
    if not mem.row_buf:
        pipelined = max(1, ceil_div(base, mem.max_out)) + gap
        return float(max(pipelined, gap + 1))

    # With row-buffer modelling, each request costs row_hit on a hit, and
    # base + row_miss on a miss. We blend by an analytical hit ratio derived
    # from the access pattern: the controller fetches K_TILE * (R or C)
    # contiguous words from each matrix, so we can estimate hits per row
    # opening as min(row_words, contig_words).
    # The caller passes the contig length via a side channel; here we assume
    # an average pattern and let the per-tile code adjust.
    hit_lat = mem.row_hit
    miss_lat = base + mem.row_miss
    # Default 50/50 here - per-tile code overrides.
    pipelined_hit = max(1, ceil_div(hit_lat, mem.max_out)) + gap
    pipelined_miss = max(1, ceil_div(miss_lat, mem.max_out)) + gap
    return float((pipelined_hit + pipelined_miss) / 2.0)


def estimate_tile_load_cycles(mem, num_words, contig_run_length):
    """Cycles to issue + drain a burst of `num_words` reads where each run of
    `contig_run_length` words is to a freshly-opened DRAM row.

    Total reads = num_words. Hits per run = contig_run_length - 1 if row_buf,
    else 0 (row_buf=0 means READ_LAT is the *hit* latency directly).
    """
    if num_words <= 0:
        return 0.0
    base = mem.read_lat
    gap = mem.read_gap
    # Per-request issue cost: (1/throughput) at steady state.
    # Throughput is min(max_out / base_lat, 1 / (gap+1)).
    if mem.row_buf:
        # Hit rate: hits per row open. A run length of R hits has R-1 hits.
        runs = max(1, ceil_div(num_words, max(1, contig_run_length)))
        hits = num_words - runs  # one miss per run, rest are hits
        misses = runs
        # Average issue latency at steady state (deeply pipelined).
        avg_issue = (hits * mem.row_hit + misses * (base + mem.row_miss)) / float(num_words)
    else:
        # row_buf=0 -> READ_LAT IS the hit-latency (used for caches).
        avg_issue = float(base)

    # words_per_cycle models memory-interface width. Narrow cache/DRAM profiles
    # use 1 word/cycle. HBM-like profiles can deliver many 32-bit words/cycle.
    width_limited_cycles_per_req = 1.0 / max(0.001, mem.words_per_cycle)
    issue_throughput_cycles_per_req = max(
        width_limited_cycles_per_req,
        max(avg_issue / float(mem.max_out),
            float(gap + 1) / max(0.001, mem.words_per_cycle)))

    issue_cycles = issue_throughput_cycles_per_req * num_words
    # First request must drain through the full pipeline; subsequent requests
    # are pipelined. Steady-state cost dominates for non-trivial bursts.
    drain = avg_issue
    return issue_cycles + drain


def estimate_tile_store_cycles(mem, num_words, contig_run_length):
    """Symmetric for writes, using write_lat / write_gap."""
    if num_words <= 0:
        return 0.0
    base = mem.write_lat
    gap = mem.write_gap
    if mem.row_buf:
        runs = max(1, ceil_div(num_words, max(1, contig_run_length)))
        hits = num_words - runs
        misses = runs
        avg_issue = (hits * mem.row_hit + misses * (base + mem.row_miss)) / float(num_words)
    else:
        avg_issue = float(base)

    # words_per_cycle models memory-interface width. Narrow cache/DRAM profiles
    # use 1 word/cycle. HBM-like profiles can deliver many 32-bit words/cycle.
    width_limited_cycles_per_req = 1.0 / max(0.001, mem.words_per_cycle)
    issue_throughput_cycles_per_req = max(
        width_limited_cycles_per_req,
        max(avg_issue / float(mem.max_out),
            float(gap + 1) / max(0.001, mem.words_per_cycle)))
    issue_cycles = issue_throughput_cycles_per_req * num_words
    drain = avg_issue
    return issue_cycles + drain


def estimate(arr, shape, mem, dataflow, dbuf, clock_mhz, mem_eff=1.0):
    """Closed-form estimator for one (array, shape, mem, dataflow, dbuf) point.

    Returns a dict of metrics matching the engine_bench CSV schema.
    """
    R = arr.rows
    C = arr.cols
    KT = arr.ktile
    M = shape.m
    N = shape.n
    K = shape.k

    # Convert fixed-bandwidth memory profiles, such as the RTX 2080 GDDR6
    # reference, into an equivalent words/cycle at this simulated clock.
    # GB/s = words/cycle * 4 bytes/word * clock_mhz / 1000.
    if getattr(mem, "fixed_peak_gbps", None) is not None:
        mem.words_per_cycle = mem.fixed_peak_gbps * 1000.0 / (4.0 * float(clock_mhz))

    m_tiles = ceil_div(M, R)
    n_tiles = ceil_div(N, C)
    k_tiles = ceil_div(K, KT)
    output_tiles = m_tiles * n_tiles
    loaded_k_tiles = output_tiles * k_tiles  # Sum of all K-tile loads.

    # Wavefront feeder runs K_active + R + C - 2 cycles. acc_clear adds 1 cycle
    # boundary (S_TILE_BEGIN), and the drain register adds (R-1)+(C-1) cycles
    # before array_done — but the feeder length already encompasses (R-1)+(C-1)
    # of fill, and the drain sits inside S_RUN. So for a K-tile that uses
    # K_active inputs along the K dimension, S_RUN takes K_active + R + C - 2
    # cycles, plus one S_START_COMPUTE cycle.
    def k_tile_compute_cycles(k_active):
        return (k_active + R + C - 2) + 1  # +1 for S_START_COMPUTE

    # Per output-tile compute cycles: sum across K tiles, plus one S_TILE_BEGIN.
    full_k_tiles = K // KT
    remainder = K - full_k_tiles * KT
    compute_cycles_per_output_tile = 1  # S_TILE_BEGIN
    for _ in range(full_k_tiles):
        compute_cycles_per_output_tile += k_tile_compute_cycles(KT)
    if remainder > 0:
        compute_cycles_per_output_tile += k_tile_compute_cycles(remainder)

    total_compute_cycles = compute_cycles_per_output_tile * output_tiles
    # The "compute_cycles" counter in RTL only counts S_RUN, not S_TILE_BEGIN
    # or S_START_COMPUTE. Subtract those: 1 + 1 = 2 boundary cycles per K tile,
    # plus 1 S_TILE_BEGIN per output tile (already inside S_TILE_BEGIN, not RUN).
    overhead_per_ktile = 1   # S_START_COMPUTE
    overhead_per_output_tile = 1  # S_TILE_BEGIN

    # Each loaded K-tile loads R*KT elements of A and KT*C elements of B.
    a_words_per_tile = R * KT
    b_words_per_tile = KT * C

    # Stationary reuse: WS skips B reload after first m_tile per n_tile;
    # NS skips A reload after first n_tile per m_tile.
    if dataflow == 1:  # WS
        # n_tile is outer, m_tile is inner. B loaded only on first m_tile.
        a_loads = m_tiles * n_tiles * k_tiles
        b_loads = n_tiles * k_tiles  # once per (n_tile, k)
    elif dataflow == 2:  # NS
        # m_tile outer, n_tile inner. A loaded only on first n_tile.
        a_loads = m_tiles * k_tiles  # once per (m_tile, k)
        b_loads = m_tiles * n_tiles * k_tiles
    else:  # OS
        a_loads = m_tiles * n_tiles * k_tiles
        b_loads = m_tiles * n_tiles * k_tiles

    a_words_total = a_loads * a_words_per_tile
    b_words_total = b_loads * b_words_per_tile
    c_words_total = M * N  # output writes (one per element)

    total_reads = a_words_total + b_words_total
    total_writes = c_words_total

    # Memory cycles per tile load (used to schedule overlap with compute).
    # Contiguous run length: A is laid out row-major with stride K, so each
    # row of A in a tile is KT contiguous words. B is laid out row-major
    # with stride N, so each row of B in a tile is C contiguous words.
    a_cycles_per_load = estimate_tile_load_cycles(mem, a_words_per_tile,
                                                  contig_run_length=KT)
    b_cycles_per_load = estimate_tile_load_cycles(mem, b_words_per_tile,
                                                  contig_run_length=C)
    load_cycles_per_full_tile = (a_cycles_per_load + b_cycles_per_load) / max(0.001, mem_eff)

    # WS/NS reuse: when stationary_*_loaded is set, we skip half of the load.
    if dataflow == 1:  # WS
        load_cycles_with_reuse = a_cycles_per_load / max(0.001, mem_eff)
    elif dataflow == 2:  # NS
        load_cycles_with_reuse = b_cycles_per_load / max(0.001, mem_eff)
    else:
        load_cycles_with_reuse = load_cycles_per_full_tile

    # Per-tile compute (one K-tile's worth of S_RUN cycles).
    compute_cycles_per_ktile_run = (KT + R + C - 2)

    # Per output tile: k_tiles K-iterations + final write-back.
    # Each K-iteration: one S_RUN. Loads issued in S_TILE_BEGIN for first tile,
    # prefetched during S_RUN for subsequent ones (DBUF=1).
    write_words_per_tile = R * C
    write_cycles_per_tile = estimate_tile_store_cycles(mem, write_words_per_tile,
                                                       contig_run_length=C)
    write_cycles_per_tile /= max(0.001, mem_eff)

    # First-K-tile load is always serial (S_WAIT_FIRST_LOAD).
    # Subsequent K-tiles overlap with S_RUN if DBUF.
    # Write-back is serial after last K-tile (S_WRITE_REQ/WAIT).

    # For an output tile we run k_tiles K-iterations + final write-back.
    # Each K-iteration: 1 S_START_COMPUTE + run_len cycles.
    # First K-tile of the output tile is preceded by 1 S_TILE_BEGIN +
    # serial_first_load. Subsequent K-tiles (k=1..k_tiles-1) overlap with
    # prefetch when DBUF=1, otherwise are serial.
    #
    # We close-form this by computing two values per output tile:
    #   serial_load_cost: cost paid when buffer cannot be filled in advance
    #   k_iter_cost:      cost of all K iterations including overlap math
    sum_run_lens = full_k_tiles * (KT + R + C - 2) + (
        (remainder + R + C - 2) if remainder > 0 else 0)
    if remainder == 0:
        last_run_len = KT + R + C - 2
        non_last_run_lens_sum = (full_k_tiles - 1) * (KT + R + C - 2)
        non_last_count = full_k_tiles - 1
    else:
        last_run_len = remainder + R + C - 2
        non_last_run_lens_sum = full_k_tiles * (KT + R + C - 2)
        non_last_count = full_k_tiles

    def per_output_tile_cost(serial_load, sub_load):
        # 1 S_TILE_BEGIN + serial_load + (k_tiles * 1 S_START_COMPUTE)
        cyc = 1.0 + serial_load + k_tiles
        # Non-last K iterations
        if dbuf:
            # max(run_len, sub_load) per non-last K-iteration
            cyc += non_last_count * max(KT + R + C - 2, sub_load)
        else:
            cyc += non_last_run_lens_sum + non_last_count * sub_load
        # Last K iteration (no further prefetch needed)
        cyc += last_run_len
        # Final write-back
        cyc += write_cycles_per_tile
        return cyc

    full_load = load_cycles_per_full_tile
    reuse_load = load_cycles_with_reuse  # half of full when reuse applies

    if dataflow == 0:
        # OS: no reuse. Every output tile pays full_load up front + full_load prefetch.
        per_tile = per_output_tile_cost(full_load, full_load)
        total_cycles = output_tiles * per_tile
    elif dataflow == 1:
        # WS: outer = n_tile, inner = m_tile.
        # First m_tile per n_tile: full load + full prefetches.
        # Subsequent m_tiles per n_tile: A-only load + A-only prefetches.
        per_tile_first = per_output_tile_cost(full_load, full_load)
        per_tile_reuse = per_output_tile_cost(reuse_load, reuse_load)
        total_cycles = n_tiles * (per_tile_first
                                  + (m_tiles - 1) * per_tile_reuse)
    else:  # NS
        # NS: outer = m_tile, inner = n_tile.
        # First n_tile per m_tile: full load + full prefetches.
        # Subsequent n_tiles per m_tile: B-only load + B-only prefetches.
        per_tile_first = per_output_tile_cost(full_load, full_load)
        per_tile_reuse = per_output_tile_cost(reuse_load, reuse_load)
        total_cycles = m_tiles * (per_tile_first
                                  + (n_tiles - 1) * per_tile_reuse)

    # The compute_cycles RTL counter only counts S_RUN.
    compute_cycles = output_tiles * sum_run_lens
    # Memory stall cycles = cycles - compute - prefetch (approximation).
    # Prefetch cycles ~ overlapped load cycles (best-effort estimate).
    if dbuf:
        prefetch_cycles_est = min(compute_cycles, max(0.0,
            (loaded_k_tiles - output_tiles) * load_cycles_per_full_tile))
    else:
        prefetch_cycles_est = 0.0

    # Memory stall cycles: time spent in *_WAIT states.
    memory_stall_cycles_est = max(0.0,
        total_cycles - compute_cycles - prefetch_cycles_est)
    compute_wait_cycles_est = 0.0  # FSM only sets this in S_WAIT_BUFFER.

    # MEM_DATA_WIDTH defaults to 32 bits = 4 bytes. The SV testbench uses
    # MEM_DATA_WIDTH = O_WORD_SIZE = 32, so each "word" load = 4 bytes.
    bytes_per_word = 4
    bytes_read = total_reads * bytes_per_word
    bytes_written = total_writes * bytes_per_word
    modeled_bytes = bytes_read + bytes_written

    macs = M * N * K
    ops = 2 * macs
    peak_macs_per_cycle = R * C
    peak_ops_per_cycle = 2 * peak_macs_per_cycle
    total_array_slots = peak_macs_per_cycle * total_cycles

    eff_macs_per_cycle = (macs / total_cycles) if total_cycles else 0.0
    eff_ops_per_cycle = (ops / total_cycles) if total_cycles else 0.0
    comp_macs_per_cycle = (macs / compute_cycles) if compute_cycles else 0.0
    comp_ops_per_cycle = (ops / compute_cycles) if compute_cycles else 0.0

    effective_gops = eff_ops_per_cycle * clock_mhz / 1000.0
    compute_gops = comp_ops_per_cycle * clock_mhz / 1000.0
    peak_gops = peak_ops_per_cycle * clock_mhz / 1000.0

    overall_pe_util = (macs / total_array_slots) if total_array_slots else 0.0
    compute_pe_util = (macs / (R * C * compute_cycles)) if compute_cycles else 0.0
    per_pe_eff = eff_ops_per_cycle / (R * C) if (R * C) else 0.0
    per_pe_comp = comp_ops_per_cycle / (R * C) if (R * C) else 0.0
    arithmetic_intensity = (ops / modeled_bytes) if modeled_bytes else 0.0
    mem_bytes_per_cycle = (modeled_bytes / total_cycles) if total_cycles else 0.0
    mem_read_bytes_per_cycle = (bytes_read / total_cycles) if total_cycles else 0.0
    mem_write_bytes_per_cycle = (bytes_written / total_cycles) if total_cycles else 0.0
    memory_stall_frac = (memory_stall_cycles_est / total_cycles) if total_cycles else 0.0
    compute_frac = (compute_cycles / total_cycles) if total_cycles else 0.0
    prefetch_frac = (prefetch_cycles_est / total_cycles) if total_cycles else 0.0
    wait_frac = (compute_wait_cycles_est / total_cycles) if total_cycles else 0.0

    return {
        "test_kind": "estimate",
        "dataflow_mode": dataflow,
        "dataflow": DATAFLOW_LABEL[dataflow],
        "slot": -1,
        "rows": R,
        "cols": C,
        "k_tile": KT,
        "m": M,
        "n": N,
        "k": K,
        "double_buffer": int(bool(dbuf)),
        "clock_mhz": clock_mhz,
        "mem_read_lat": mem.read_lat,
        "mem_write_lat": mem.write_lat,
        "read_gap": mem.read_gap,
        "write_gap": mem.write_gap,
        "max_outstanding": mem.max_out,
        "banks": mem.banks,
        "row_words": mem.row_words,
        "row_hit": mem.row_hit,
        "row_miss": mem.row_miss,
        "row_buffer": mem.row_buf,
        "mem_words_per_cycle": "%.6f" % mem.words_per_cycle,
        "mem_peak_GBps": "%.6f" % ((mem.fixed_peak_gbps if getattr(mem, "fixed_peak_gbps", None) is not None else
                                      mem.words_per_cycle * 4.0 * clock_mhz / 1000.0)),
        "cycles": int(round(total_cycles)),
        "compute_cycles": int(compute_cycles),
        "memory_stall_cycles": int(round(memory_stall_cycles_est)),
        "prefetch_cycles": int(round(prefetch_cycles_est)),
        "compute_wait_cycles": int(round(compute_wait_cycles_est)),
        "mem_cycles": int(round(total_cycles)),
        "reads": total_reads,
        "writes": total_writes,
        "mem_reads": total_reads,
        "mem_writes": total_writes,
        "bytes_read": bytes_read,
        "bytes_written": bytes_written,
        "modeled_bytes": modeled_bytes,
        "loaded_k_tiles": loaded_k_tiles,
        "output_tiles": output_tiles,
        "macs": macs,
        "ops": ops,
        "peak_macs_per_cycle": peak_macs_per_cycle,
        "peak_ops_per_cycle": peak_ops_per_cycle,
        "effective_macs_per_cycle": "%.6f" % eff_macs_per_cycle,
        "effective_ops_per_cycle": "%.6f" % eff_ops_per_cycle,
        "compute_macs_per_cycle": "%.6f" % comp_macs_per_cycle,
        "compute_ops_per_cycle": "%.6f" % comp_ops_per_cycle,
        "effective_gops": "%.6f" % effective_gops,
        "compute_gops": "%.6f" % compute_gops,
        "peak_gops": "%.6f" % peak_gops,
        "overall_pe_util": "%.6f" % overall_pe_util,
        "compute_pe_util": "%.6f" % compute_pe_util,
        "per_pe_effective_ops_per_cycle": "%.6f" % per_pe_eff,
        "per_pe_compute_ops_per_cycle": "%.6f" % per_pe_comp,
        "arithmetic_intensity": "%.6f" % arithmetic_intensity,
        "mem_bytes_per_cycle": "%.6f" % mem_bytes_per_cycle,
        "mem_read_bytes_per_cycle": "%.6f" % mem_read_bytes_per_cycle,
        "mem_write_bytes_per_cycle": "%.6f" % mem_write_bytes_per_cycle,
        "memory_stall_frac": "%.6f" % memory_stall_frac,
        "compute_frac": "%.6f" % compute_frac,
        "prefetch_frac": "%.6f" % prefetch_frac,
        "compute_wait_frac": "%.6f" % wait_frac,
        "array": "%dx%dx%d" % (R, C, KT),
        "shape": str(shape),
        "mem_cfg": str(mem),
        "array_dataflow": "%dx%dx%d/%s" % (R, C, KT, DATAFLOW_LABEL[dataflow]),
    }

PREFERRED_COLUMNS = [
    "timestamp", "case_index", "test_kind", "array", "dataflow", "dataflow_mode",
    "array_dataflow", "shape", "mem_cfg", "slot",
    "rows", "cols", "k_tile", "m", "n", "k", "double_buffer",
    "clock_mhz", "mem_read_lat", "mem_write_lat", "read_gap", "write_gap",
    "max_outstanding", "banks", "row_words", "row_hit", "row_miss", "row_buffer",
    "mem_words_per_cycle", "mem_peak_GBps",
    "cycles", "compute_cycles", "memory_stall_cycles", "prefetch_cycles",
    "compute_wait_cycles", "mem_cycles", "reads", "writes", "mem_reads",
    "mem_writes", "bytes_read", "bytes_written", "modeled_bytes",
    "loaded_k_tiles", "output_tiles", "macs", "ops",
    "peak_macs_per_cycle", "peak_ops_per_cycle",
    "effective_macs_per_cycle", "effective_ops_per_cycle",
    "compute_macs_per_cycle", "compute_ops_per_cycle",
    "effective_gops", "compute_gops", "peak_gops",
    "overall_pe_util", "compute_pe_util",
    "per_pe_effective_ops_per_cycle", "per_pe_compute_ops_per_cycle",
    "arithmetic_intensity", "mem_bytes_per_cycle",
    "mem_read_bytes_per_cycle", "mem_write_bytes_per_cycle",
    "memory_stall_frac", "compute_frac", "prefetch_frac", "compute_wait_frac",
]

def write_csv(path, rows, append=False):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    keys = set()
    for r in rows:
        keys.update(r.keys())
    extras = sorted(keys - set(PREFERRED_COLUMNS))
    fieldnames = PREFERRED_COLUMNS + extras

    file_exists = path.exists() and path.stat().st_size > 0
    mode = "a" if (append and file_exists) else "w"
    write_header = (not file_exists) or (not append)

    with path.open(mode, newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        if write_header:
            writer.writeheader()
        for r in rows:
            writer.writerow(r)

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--arrays", default="16x16x32,32x32x64,64x64x128",
                   help="Comma-separated ROWSxCOLSxKTILE list.")
    p.add_argument("--shapes", default="128x128x128,256x256x256,1024x1024x1024",
                   help="Comma-separated MxNxK list.")
    p.add_argument("--dataflows", default="os,ws,ns",
                   help="Comma-separated dataflow names (os,ws,ns) or modes (0,1,2).")
    p.add_argument("--mem", default="l1,l2,llc,dram",
                   help="Memory profiles (l1,l2,llc,dram,hbm,hbm_high,rtx2080,gpu_gddr6) or raw specs. Raw 11-field format adds words_per_cycle.")
    p.add_argument("--double-buffer", default="0,1",
                   help="Comma-separated DBUF values.")
    p.add_argument("--clock-mhz", type=int, default=1000)
    p.add_argument("--memory-efficiency", type=float, default=1.0,
                   help="Calibration factor [0,1]; lower inflates memory cost.")
    p.add_argument("--out", default="estimated_sweep.csv",
                   help="Output CSV path.")
    p.add_argument("--append", action="store_true",
                   help="Append to --out instead of overwriting.")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    arrays = parse_arrays(args.arrays)
    shapes = parse_shapes(args.shapes)
    dfs = parse_dataflows(args.dataflows)
    mems = parse_mem(args.mem)
    dbufs = parse_int_list(args.double_buffer)

    if not args.quiet:
        print("Arrays:    %s" % ", ".join(str(a) for a in arrays))
        print("Shapes:    %s" % ", ".join(str(s) for s in shapes))
        print("Dataflows: %s" % ", ".join(DATAFLOW_LABEL[d] for d in dfs))
        print("Memories:  %s" % ", ".join(str(m) for m in mems))
        print("DBUFs:     %s" % ", ".join(str(d) for d in dbufs))

    rows = []
    case_idx = 0
    timestamp = datetime.now().isoformat(timespec="seconds")
    for arr in arrays:
        for shape in shapes:
            for df in dfs:
                for mem in mems:
                    for dbuf in dbufs:
                        case_idx += 1
                        row = estimate(arr, shape, mem, df, dbuf,
                                       args.clock_mhz, args.memory_efficiency)
                        row["case_index"] = case_idx
                        row["timestamp"] = timestamp
                        rows.append(row)
                        if not args.quiet:
                            print("[%4d] %-14s shape=%-16s df=%s mem=%-10s dbuf=%d -> "
                                  "cycles=%-9d eff=%6s GOP/s util=%5s%%" % (
                                      case_idx, str(arr), str(shape),
                                      DATAFLOW_LABEL[df], str(mem), dbuf,
                                      row["cycles"],
                                      row["effective_gops"],
                                      ("%.1f" % (float(row["compute_pe_util"]) * 100.0))))

    write_csv(args.out, rows, append=args.append)
    if not args.quiet:
        print("Wrote %d rows to %s%s" % (
            len(rows), args.out, " (appended)" if args.append else ""))


if __name__ == "__main__":
    sys.exit(main())
