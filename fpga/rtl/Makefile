VCS 	   ?= vcs -sverilog -q -debug +vcs+lic+wait
SRCDIR 	   := src/
TESTDIR    := test/
SRC	   := $(SRCDIR)*.sv

ROWS       ?= 4
COLS       ?= 4
KTILE      ?= 8
M          ?= 8
N          ?= 8
K          ?= 8
READ_LAT   ?= 40
WRITE_LAT  ?= 20
READ_GAP   ?= 0
WRITE_GAP  ?= 0
CLOCK_MHZ  ?= 100
DBUF       ?= 1

BENCH_PARAMS := \
	-pvalue+sa_benchmark_test.NUM_ROWS=$(ROWS) \
	-pvalue+sa_benchmark_test.NUM_COLS=$(COLS) \
	-pvalue+sa_benchmark_test.K_TILE=$(KTILE) \
	-pvalue+sa_benchmark_test.M_DIM=$(M) \
	-pvalue+sa_benchmark_test.N_DIM=$(N) \
	-pvalue+sa_benchmark_test.K_DIM=$(K) \
	-pvalue+sa_benchmark_test.READ_LATENCY=$(READ_LAT) \
	-pvalue+sa_benchmark_test.WRITE_LATENCY=$(WRITE_LAT) \
	-pvalue+sa_benchmark_test.READ_ACCEPT_GAP=$(READ_GAP) \
	-pvalue+sa_benchmark_test.WRITE_ACCEPT_GAP=$(WRITE_GAP) \
	-pvalue+sa_benchmark_test.CLOCK_MHZ=$(CLOCK_MHZ) \
	-pvalue+sa_benchmark_test.ENABLE_DOUBLE_BUFFER=$(DBUF)

.PHONY: clean regress bench-sa bench-engine

test-%:
	$(VCS) -o $*_test +incdir+$(SRCDIR) $(TESTDIR)$*_test.sv
	./$*_test

check:
	$(VCS) -o check +incdir+$(SRCDIR) $(TESTDIR)single_pe_test.sv

regress: test-single_pe test-systolic_array_os test-systolic_array_ws test-systolic_array_ns test-feeder test-main_memory_model test-tiled_gemm_accelerator test-systolic_gemm_engine

bench-sa:
	$(VCS) $(BENCH_PARAMS) -o sa_benchmark_test +incdir+$(SRCDIR) $(TESTDIR)sa_benchmark_test.sv
	./sa_benchmark_test

bench-engine:
	$(VCS) -o systolic_gemm_engine_test +incdir+$(SRCDIR) $(TESTDIR)systolic_gemm_engine_test.sv
	./systolic_gemm_engine_test

clean:
	rm -rf csrc *.daidir *_test randtest ucli.key simv* DVEfiles *vpd .restartSimSession* .*dve_rebuild* check*
