# Makefile for parameterized systolic GEMM simulation and benchmarking.
# Usage examples:
#   make bench-engine ROWS=8 COLS=8 KTILE=16 M=64 N=64 K=64 READ_LAT=12 WRITE_LAT=4 ROW_BUF=0
#   make sweep-hw

VCS        ?= vcs -sverilog -q -debug +vcs+lic+wait
SRCDIR     ?= src
TESTDIR    ?= test
BUILDDIR   ?= build
PYTHON     ?= python3.6

# Systolic-array slot under test. The benchmark maps ROWS/COLS/KTILE into SLOT0
# and selects SLOT0 by default, so every invocation benchmarks one exact array.
SLOT       ?= 0
ROWS       ?= 4
COLS       ?= 4
KTILE      ?= 8
M          ?= 32
N          ?= 32
K          ?= 32
DBUF       ?= 1
CLOCK_MHZ  ?= 100

# Memory-model parameters.
# Cache-like default: approximate private L2 hit latency.
# For cache experiments keep ROW_BUF=0 so READ_LAT/WRITE_LAT are the actual hit latencies.
READ_LAT   ?= 12
WRITE_LAT  ?= 4
READ_GAP   ?= 0
WRITE_GAP  ?= 0
MAX_OUT    ?= 32
BANKS      ?= 8
ROW_WORDS  ?= 64
ROW_HIT    ?= 1
ROW_MISS   ?= 0
ROW_BUF    ?= 0
DEPTH_WORDS ?= 33554432
VALUE_MAX  ?= 9

ENGINE_BIN := $(BUILDDIR)/systolic_gemm_engine_test

ENGINE_PARAMS := \
	-pvalue+systolic_gemm_engine_test.SELECT_SLOT=$(SLOT) \
	-pvalue+systolic_gemm_engine_test.SLOT0_ROWS=$(ROWS) \
	-pvalue+systolic_gemm_engine_test.SLOT0_COLS=$(COLS) \
	-pvalue+systolic_gemm_engine_test.SLOT0_K_TILE=$(KTILE) \
	-pvalue+systolic_gemm_engine_test.SLOT1_ROWS=$(ROWS) \
	-pvalue+systolic_gemm_engine_test.SLOT1_COLS=$(COLS) \
	-pvalue+systolic_gemm_engine_test.SLOT1_K_TILE=$(KTILE) \
	-pvalue+systolic_gemm_engine_test.SLOT2_ROWS=$(ROWS) \
	-pvalue+systolic_gemm_engine_test.SLOT2_COLS=$(COLS) \
	-pvalue+systolic_gemm_engine_test.SLOT2_K_TILE=$(KTILE) \
	-pvalue+systolic_gemm_engine_test.M_DIM=$(M) \
	-pvalue+systolic_gemm_engine_test.N_DIM=$(N) \
	-pvalue+systolic_gemm_engine_test.K_DIM=$(K) \
	-pvalue+systolic_gemm_engine_test.ENABLE_DOUBLE_BUFFER=$(DBUF) \
	-pvalue+systolic_gemm_engine_test.CLOCK_MHZ=$(CLOCK_MHZ) \
	-pvalue+systolic_gemm_engine_test.READ_LATENCY=$(READ_LAT) \
	-pvalue+systolic_gemm_engine_test.WRITE_LATENCY=$(WRITE_LAT) \
	-pvalue+systolic_gemm_engine_test.READ_ACCEPT_GAP=$(READ_GAP) \
	-pvalue+systolic_gemm_engine_test.WRITE_ACCEPT_GAP=$(WRITE_GAP) \
	-pvalue+systolic_gemm_engine_test.MAX_OUTSTANDING=$(MAX_OUT) \
	-pvalue+systolic_gemm_engine_test.BANKS=$(BANKS) \
	-pvalue+systolic_gemm_engine_test.ROW_WORDS=$(ROW_WORDS) \
	-pvalue+systolic_gemm_engine_test.ROW_HIT_LATENCY=$(ROW_HIT) \
	-pvalue+systolic_gemm_engine_test.ROW_MISS_PENALTY=$(ROW_MISS) \
	-pvalue+systolic_gemm_engine_test.MODEL_ROW_BUFFER=$(ROW_BUF) \
	-pvalue+systolic_gemm_engine_test.DEPTH_WORDS=$(DEPTH_WORDS) \
	-pvalue+systolic_gemm_engine_test.VALUE_MAX=$(VALUE_MAX)

.PHONY: clean bench-engine bench-sa sweep-hw

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

bench-engine: $(BUILDDIR)
	$(VCS) $(ENGINE_PARAMS) -o $(ENGINE_BIN) +incdir+$(SRCDIR) $(TESTDIR)/systolic_gemm_engine_test.sv
	./$(ENGINE_BIN)

# Alias retained for older scripts.
bench-sa: bench-engine

sweep-hw:
	$(PYTHON) scripts/sweep_hw.py --rtl-dir . --out $(BUILDDIR)/fpga_sweep.csv --plot-dir $(BUILDDIR)/plots

clean:
	rm -rf $(BUILDDIR) csrc *.daidir *_test randtest ucli.key simv* DVEfiles *vpd \
	       .restartSimSession* .*dve_rebuild* check* *.log
