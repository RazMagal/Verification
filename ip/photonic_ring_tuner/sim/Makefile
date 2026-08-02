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
#   The DEFAULT targets are pure SystemVerilog and are exactly what they have
#   always been: no +define+RING_DPI, no C, no shared library. The optional
#   DPI-C layer lives behind the *_dpi targets at the bottom of this file.
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

# ==========================================================================
# OPTIONAL DPI-C LAYER  (+define+RING_DPI)
# ==========================================================================
# Everything above this line is the default flow and stays pure SystemVerilog.
# The targets below compile the same sources WITH +define+RING_DPI, which turns
# on common/dpi/photonics_dpi_pkg.sv (the import "DPI-C" / export "DPI-C"
# declarations) and the RING_MODEL_DPI / RING_MODEL_COMPARE backends in
# dv/optics/ring_model.sv.
#
# There is one target per simulator because DPI LINKAGE IS NOT PORTABLE, and
# that is the actual work here:
#   * VCS      elaborates simv against the shared object with -sv_lib.
#   * Questa   loads the same shared object at vsim time with -sv_lib, and
#              vlog -dpiheader writes the prototypes it expects, which is worth
#              diffing against the hand-written common/dpi/photonics_dpi.h.
#   * Xcelium  also loads it, but at xrun time (one step, no separate elaborate)
#              and with its own -sv_lib spelling.
#
# ALL THREE LOAD THE SAME ARTIFACT -- $(DPI_LIB), built once by
# `make -C common/dpi`. VCS used to be handed $(DPI_SRC) with its own -CFLAGS,
# which compiled a SECOND build of the C (different flags, different optimizer,
# and it did not even need the .so it had just depended on). For an EQUIVALENCE
# test that is apples-to-oranges: "the C model matches the SV model" would have
# meant a different binary under VCS than under Questa/Xcelium, and a
# -O2-vs--O0 floating-point difference is exactly the class of bug this test
# exists to catch. One library, three loaders.
#
# -sv_lib takes the path WITHOUT the .so suffix. Override DPI_LIBBASE if the C
# side names its library something else:
#     make questa_dpi DPI_LIBBASE=$(ROOT)/common/dpi/libphotonics
DPI_DIR     := $(ROOT)/common/dpi
DPI_LIBBASE ?= $(DPI_DIR)/libphotonics_dpi
DPI_LIB     := $(DPI_LIBBASE).so
BUILD       := $(CURDIR)/build

# Which backend the DPI runs use: sv | dpi | compare. `compare` runs BOTH models
# in lockstep and checks them against each other every clock, which is the point.
RING_MODEL ?= compare

# WHICH TEST the *_dpi targets run. The default flow's knob is TEST=, and it used
# to be silently ignored here: `make questa_dpi TEST=foo` ran the equivalence
# test and reported it under the name of a test that never executed. So TEST= now
# wins WHEN THE USER ACTUALLY SET IT ($(origin ...)), and only an unset TEST --
# i.e. TEST still sitting at this file's own default -- falls through to the
# equivalence test. DPI_TEST= on the command line still beats both (a command-
# line variable overrides these `?=` assignments outright), which is what
# regress_dpi_all relies on.
DPI_TEST_DEFAULT := photonic_ring_tuner_dpi_equiv_test
# "command line" / "environment [override]" -> the user set TEST; "file" -> it is
# still the default at the top of this Makefile.
TEST_IS_USER_SET := $(filter command environment,$(firstword $(origin TEST)))
ifneq ($(TEST_IS_USER_SET),)
DPI_TEST   ?= $(TEST)
else
DPI_TEST   ?= $(DPI_TEST_DEFAULT)
endif
DPI_PLUS    = +UVM_TESTNAME=$(DPI_TEST) +UVM_VERBOSITY=$(UVM_VERBOSITY) \
              +RING_MODEL=$(RING_MODEL)

# The C side (photonics_dpi.{h,c}, its own unit tests and Makefile) is owned by
# common/dpi; this just asks it to build. If the library is missing at run time
# the simulator's loader is what complains, so fail early and say why.
.PHONY: dpi-lib
dpi-lib:
	$(MAKE) -C $(DPI_DIR)
	@test -f $(DPI_LIB) || { \
	  echo "ERROR: $(DPI_LIB) was not produced by 'make -C $(DPI_DIR)'."; \
	  echo "       Override the name with DPI_LIBBASE=<path without .so>."; \
	  exit 1; }

# ---- Synopsys VCS : elaborate simv_dpi against the SAME shared object -------
# -sv_lib takes the path without the .so suffix, same spelling as Questa and
# Xcelium below. Deliberately NOT `vcs $(DPI_SRC) -CFLAGS ...`: that would build
# a second, differently-compiled copy of the C model and quietly test something
# other than what the other two simulators load (see the note above). If a VCS
# install prefers the library at run time instead of at elaboration, move the
# flag: `./simv_dpi -sv_lib $(DPI_LIBBASE) ...`.
vcs_dpi: dpi-lib
	cd $(ROOT) && vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
	  -debug_access+all +define+RING_DPI -f $(FILES) \
	  -sv_lib $(DPI_LIBBASE) \
	  -o $(ROOT)/simv_dpi
	cd $(ROOT) && ./simv_dpi $(DPI_PLUS) +ntb_random_seed=$(SEED)

# ---- Mentor Questa : vlog -dpiheader, then vsim -sv_lib <lib without .so> ----
# The generated header is the tool's OWN view of the ABI. Diffing it against the
# hand-written common/dpi/photonics_dpi.h is a five-second check that catches the
# classic DPI mismatches (int vs long, real vs double, a missing `context`,
# an output real that should be a double*) before they become a run-time crash.
questa_dpi: dpi-lib
	@mkdir -p $(BUILD)
	cd $(ROOT) && vlib work && vlog -sv -mfcu -timescale "1ns/1ps" \
	  +define+RING_DPI -dpiheader $(BUILD)/photonics_dpi_vlog.h \
	  +incdir+$(QUESTA_UVM_HOME)/src $(QUESTA_UVM_HOME)/src/uvm_pkg.sv \
	  -f $(FILES)
	@echo "--- vlog's view of the ABI is in $(BUILD)/photonics_dpi_vlog.h"
	@echo "---   diff it against $(DPI_DIR)/photonics_dpi.h"
	cd $(ROOT) && vsim -c -do "run -all; quit" photonic_ring_tuner_tb_top \
	  -sv_lib $(DPI_LIBBASE) $(DPI_PLUS) -sv_seed $(SEED)

# ---- Cadence Xcelium : single step, loads the shared object at xrun time ----
xrun_dpi: dpi-lib
	cd $(ROOT) && xrun -64bit -sv -uvm -uvmhome CDNS-1.2 -timescale 1ns/1ps \
	  -access +rwc +define+RING_DPI -f $(FILES) \
	  -sv_lib $(DPI_LIBBASE) \
	  $(DPI_PLUS) -svseed $(SEED)

# ---- multi-seed equivalence regression -----------------------------------
# The ring is randomized per seed, so each seed is a different physical problem
# and therefore a different trajectory through both models. One seed proving
# "the C model agrees" would be worth very little.
DPI_SEEDS = 1 2 3 4 5 6 7 8
DPI_SIM  ?= questa_dpi

regress_dpi:
	@for s in $(DPI_SEEDS); do \
	  echo "=== $(DPI_TEST) [$(RING_MODEL)] seed=$$s ==="; \
	  $(MAKE) $(DPI_SIM) DPI_TEST=$(DPI_TEST) RING_MODEL=$(RING_MODEL) SEED=$$s \
	    || exit 1; \
	done

# The whole existing suite re-run against the C model as the ONLY backend --
# the other half of qualifying it: not just "it matches on one test" but "every
# verdict this environment can reach still holds when C closes the loop".
regress_dpi_all:
	@for t in $(TESTS); do \
	  for s in 1 2 3; do \
	    echo "=== $$t [dpi] seed=$$s ==="; \
	    $(MAKE) $(DPI_SIM) DPI_TEST=$$t RING_MODEL=dpi SEED=$$s || exit 1; \
	  done; \
	done

clean:
	rm -rf $(ROOT)/work $(ROOT)/simv $(ROOT)/simv_dpi $(ROOT)/simv.daidir \
	       $(ROOT)/simv_dpi.daidir $(ROOT)/csrc \
	       $(ROOT)/xcelium.d $(ROOT)/*.log $(ROOT)/*.vcd $(ROOT)/*.shm \
	       $(BUILD) transcript vsim.wlf

.PHONY: questa questa2 vcs xrun regress clean \
        vcs_dpi questa_dpi xrun_dpi regress_dpi regress_dpi_all
