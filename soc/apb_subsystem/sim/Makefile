# ============================================================================
# apb_subsystem UVM env - simulation Makefile (Questa / VCS / Xcelium)
#
#   Runs are launched from the REPO ROOT so the repo-root-relative paths in
#   run.f resolve. run.f already carries +define+APB_ADDR_W=12, but every target
#   ALSO passes it explicitly at compile so the width is set regardless of flow.
#
#     make questa TEST=apb_subsystem_concurrent_timers_test
#     make vcs    TEST=apb_subsystem_mem_test SEED=7
#     make xrun   TEST=apb_subsystem_decode_error_test
#     make regress            # all tests on Questa, several seeds
#
#   Requires UVM-1.2 from the tool install (-uvm / -ntb_opts uvm-1.2 as needed).
# ============================================================================

# repo root = three levels up from soc/apb_subsystem/sim
ROOT    := $(abspath $(CURDIR)/../../..)
FILES   := soc/apb_subsystem/sim/run.f
TEST    ?= apb_subsystem_smoke_test
SEED    ?= 1
UVM_VERBOSITY ?= UVM_MEDIUM
DEFINE  := +define+APB_ADDR_W=12

PLUS = +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(UVM_VERBOSITY)

# ---- Mentor Questa (single-step qverilog) --------------------------------
questa:
	cd $(ROOT) && qverilog -sv -mfcu -timescale=1ns/1ps \
	  $(DEFINE) +define+UVM_NO_DPI -f $(FILES) \
	  -R +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(UVM_VERBOSITY) -sv_seed $(SEED)

# ---- Mentor Questa (explicit vlog/vsim) ----------------------------------
questa2:
	cd $(ROOT) && vlib work && vlog -sv -mfcu -timescale "1ns/1ps" $(DEFINE) \
	  +incdir+$(QUESTA_UVM_HOME)/src $(QUESTA_UVM_HOME)/src/uvm_pkg.sv \
	  -f $(FILES)
	cd $(ROOT) && vsim -c -do "run -all; quit" apb_subsystem_tb_top \
	  $(PLUS) -sv_seed $(SEED)

# ---- Synopsys VCS --------------------------------------------------------
vcs:
	cd $(ROOT) && vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
	  $(DEFINE) -debug_access+all -f $(FILES) -o $(ROOT)/simv
	cd $(ROOT) && ./simv $(PLUS) +ntb_random_seed=$(SEED)

# ---- Cadence Xcelium -----------------------------------------------------
xrun:
	cd $(ROOT) && xrun -64bit -sv -uvm -uvmhome CDNS-1.2 -timescale 1ns/1ps \
	  $(DEFINE) -access +rwc -f $(FILES) \
	  $(PLUS) -svseed $(SEED)

# ---- multi-seed regression (Questa qverilog) -----------------------------
TESTS = apb_subsystem_smoke_test apb_subsystem_concurrent_timers_test \
        apb_subsystem_mem_test apb_subsystem_decode_error_test \
        apb_subsystem_rand_test
SEEDS = 1 2 3 4 5

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
