# ============================================================================
# photonic_ring_tuner UVM env - simulation Makefile (Questa / VCS / Xcelium)
#
#   Runs are launched from the REPO ROOT so the repo-root-relative paths in
#   run.f resolve. Pick a test with TEST=<name> and a seed with SEED=<n>.
#
#     make questa TEST=photonic_ring_tuner_lock_test
#     make vcs    TEST=photonic_ring_tuner_settle_short_test SEED=7
#     make xrun   TEST=photonic_ring_tuner_reg_test
#     make regress            # all tests on Questa, several seeds
#
#   Requires UVM-1.2 from the tool install (-uvm / -uvmhome as appropriate).
#   Default APB widths (ADDR=8, DATA=32) => no APB_ADDR_W define needed.
#
#   The optical model (dv/optics/ring_model.sv) is real-valued and deliberately
#   NON-SYNTHESIZABLE; it belongs to this filelist only.
# ============================================================================

# repo root = three levels up from ip/photonic_ring_tuner/sim
ROOT    := $(abspath $(CURDIR)/../../..)
FILES   := ip/photonic_ring_tuner/sim/run.f
TEST    ?= photonic_ring_tuner_smoke_test
SEED    ?= 1
UVM_VERBOSITY ?= UVM_MEDIUM

PLUS = +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(UVM_VERBOSITY)

# ---- Mentor Questa -------------------------------------------------------
questa:
	cd $(ROOT) && qverilog -sv -mfcu -timescale=1ns/1ps \
	  +define+UVM_NO_DPI -f $(FILES) \
	  -R +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(UVM_VERBOSITY) -sv_seed $(SEED)

# explicit vlog/vsim flow (preferred on most Questa installs)
questa2:
	cd $(ROOT) && vlib work && vlog -sv -mfcu -timescale "1ns/1ps" \
	  +incdir+$(QUESTA_UVM_HOME)/src $(QUESTA_UVM_HOME)/src/uvm_pkg.sv \
	  -f $(FILES)
	cd $(ROOT) && vsim -c -do "run -all; quit" photonic_ring_tuner_tb_top \
	  $(PLUS) -sv_seed $(SEED)

# ---- Synopsys VCS --------------------------------------------------------
vcs:
	cd $(ROOT) && vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
	  -debug_access+all -f $(FILES) -o $(ROOT)/simv
	cd $(ROOT) && ./simv $(PLUS) +ntb_random_seed=$(SEED)

# ---- Cadence Xcelium -----------------------------------------------------
xrun:
	cd $(ROOT) && xrun -64bit -sv -uvm -uvmhome CDNS-1.2 -timescale 1ns/1ps \
	  -access +rwc -f $(FILES) \
	  $(PLUS) -svseed $(SEED)

# ---- multi-seed regression (Questa qverilog) -----------------------------
# The optical tests are constrained-RANDOM (the ring is randomized per seed),
# so a single seed proves very little: run the list across seeds.
TESTS = photonic_ring_tuner_smoke_test photonic_ring_tuner_reg_test \
        photonic_ring_tuner_error_test photonic_ring_tuner_lock_test \
        photonic_ring_tuner_lock_loss_test \
        photonic_ring_tuner_settle_short_test photonic_ring_tuner_dark_test \
        photonic_ring_tuner_rail_test photonic_ring_tuner_rail_w1c_race_test \
        photonic_ring_tuner_ratio_test
SEEDS = 1 2 3 4 5 6 7 8

regress:
	@for t in $(TESTS); do \
	  for s in $(SEEDS); do \
	    echo "=== $$t seed=$$s ==="; \
	    $(MAKE) questa TEST=$$t SEED=$$s || exit 1; \
	  done; \
	done

clean:
	rm -rf $(ROOT)/work $(ROOT)/simv $(ROOT)/simv.daidir $(ROOT)/csrc \
	       $(ROOT)/xcelium.d $(ROOT)/*.log $(ROOT)/*.vcd $(ROOT)/*.shm \
	       transcript vsim.wlf

.PHONY: questa questa2 vcs xrun regress clean
