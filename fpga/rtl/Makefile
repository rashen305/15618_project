VCS 	   := vcs -sverilog -q -debug
SRCDIR 	   := src/
TESTDIR    := test/
SRC		   := $(SRCDIR)*.sv

.PHONY: clean

test-%:
	$(VCS) -o $*_test +incdir+$(SRCDIR) $(TESTDIR)$*_test.sv; ./$*_test

clean:
	rm -rf csrc *.daidir *_test randtest ucli.key simv* DVEfiles *vpd .restartSimSession* .*dve_rebuild*
