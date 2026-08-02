# ============================================================================
# common/dpi -- C model of the microring optics, exported to SV over DPI-C.
#
#   make            build libphotonics_dpi.so   (for a SIMULATOR to load)
#   make standalone build libphotonics_dpi_standalone.so (no simulator needed)
#   make test       build AND RUN the standalone unit tests (gcc only)
#   make test-asan  same tests under AddressSanitizer + UBSan
#   make info       show what was auto-detected (svdpi.h, compiler)
#   make clean      remove build products
#
#   NOTHING HERE NEEDS A SIMULATOR. svdpi.h is used when a simulator install
#   provides one, and the build degrades to plain C when it does not -- the ABI
#   is deliberately all plain C scalars (see photonics_dpi.h), so the physics
#   and its tests are buildable on any machine with gcc. Requiring a licence to
#   run the unit tests would defeat the purpose of putting the model in C.
#
#   TWO SHARED OBJECTS, ON PURPOSE:
#     libphotonics_dpi.so             sv_ring_event is UNDEFINED. Only a
#                                     simulator (which exports it) can load it.
#     libphotonics_dpi_standalone.so  links a stub sv_ring_event, so dlopen /
#                                     python ctypes can load it. Never feed
#                                     this one to a simulator.
#   See the comment on the `standalone` target for why this is not one library
#   with a weak symbol.
# ============================================================================

# `CC ?= gcc` does NOT work here: make PREDEFINES CC = cc, so the variable is
# already set and ?= never fires (the symptom is `make info` printing "cc").
# Only override the built-in default; an environment or command-line CC wins.
ifeq ($(origin CC),default)
  CC := gcc
endif

CSTD     ?= -std=c99
OPT      ?= -O2
WARN     := -Wall -Wextra -Wpedantic -Wshadow -Wstrict-prototypes
CFLAGS   ?= $(CSTD) $(OPT) $(WARN)
LDLIBS   := -lm

LIB      := libphotonics_dpi.so
SALIB    := libphotonics_dpi_standalone.so
SRC      := photonics_dpi.c
HDR      := photonics_dpi.h
TEST_SRC := test/test_photonics_dpi.c
TEST_BIN := test/test_photonics_dpi
ASAN_BIN := test/test_photonics_dpi_asan

# ---- locate svdpi.h (optional) --------------------------------------------
# Simulators install it in different places; take the first one that exists.
#
# Done in the shell, NOT with $(wildcard): make splits variables on whitespace,
# so $(wildcard $(d)/svdpi.h) silently drops any path containing a space -- and
# real installs have them ("/opt/Questa Sim 2023.4/include"). The loop below
# quotes each candidate, and every USE of $(SVDPI_DIR) is quoted too.
# ${VAR:+...} keeps an unset variable from expanding to a bare "/include".
SVDPI_DIR := $(shell \
  for d in \
      "$${PHOTONICS_SVDPI_DIR:+$$PHOTONICS_SVDPI_DIR}" \
      "$${VCS_HOME:+$$VCS_HOME/include}" \
      "$${QUESTA_HOME:+$$QUESTA_HOME/include}" \
      "$${MTI_HOME:+$$MTI_HOME/include}" \
      "$${MODEL_TECH:+$$MODEL_TECH/../include}" \
      "$${XCELIUM_HOME:+$$XCELIUM_HOME/tools/include}" \
      "$${CDS_INST_DIR:+$$CDS_INST_DIR/tools/include}" \
      /usr/local/include /usr/include ; do \
    [ -n "$$d" ] || continue ; \
    if [ -r "$$d/svdpi.h" ] ; then printf '%s' "$$d" ; break ; fi ; \
  done)

# An explicitly-set PHOTONICS_SVDPI_DIR is a statement of intent: if it does not
# actually hold an svdpi.h, say so instead of quietly building without it.
ifneq ($(PHOTONICS_SVDPI_DIR),)
  ifeq ($(SVDPI_DIR),)
    $(warning PHOTONICS_SVDPI_DIR is set but no svdpi.h was found there:)
    $(warning   "$(PHOTONICS_SVDPI_DIR)/svdpi.h" is not readable)
    $(warning building WITHOUT svdpi.h -- fine for the tests, check the path)
  endif
endif

ifneq ($(SVDPI_DIR),)
  SVDPI_CFLAGS := -I"$(SVDPI_DIR)" -DPHOTONICS_DPI_HAVE_SVDPI=1
else
  SVDPI_CFLAGS :=
endif

# ---- sanitizers ------------------------------------------------------------
# -fno-sanitize-recover makes UB fatal instead of merely printed, so `make
# test-asan` fails the build the way a regression should.
SAN_FLAGS := -fsanitize=address,undefined -fno-sanitize-recover=undefined \
             -fno-omit-frame-pointer -g

.PHONY: all standalone test test-asan info clean

all: $(LIB)

# -shared -fPIC: loaded by the simulator at elaboration (vsim -sv_lib /
# xrun -sv_lib). Undefined symbols are EXPECTED and must stay undefined:
# sv_ring_event lives in the simulator, so do NOT add -Wl,--no-undefined.
$(LIB): $(SRC) $(HDR)
	$(CC) $(CFLAGS) $(SVDPI_CFLAGS) -shared -fPIC -o $@ $(SRC) $(LDLIBS)

# The genuinely self-contained artifact: same model, plus a stub sv_ring_event
# (photonics_dpi.c, under -DPHOTONICS_DPI_STANDALONE). This is what a Python
# ctypes script or a fuzzer loads; $(LIB) above cannot be dlopen'd at all
# without a definition of sv_ring_event, and loading it RTLD_LAZY aborts the
# process the first time the ring crosses resonance.
#
# Why two artifacts rather than one library with a WEAK sv_ring_event: weak
# preemption depends on load order and on the simulator exporting its DPI
# symbols globally. Where it does not happen, the library still links and runs
# and silently swallows every event -- which spec 7.7(4) makes a must-fail
# condition. An undefined symbol fails loudly at load time instead.
standalone: $(SALIB)

$(SALIB): $(SRC) $(HDR)
	$(CC) $(CFLAGS) $(SVDPI_CFLAGS) -DPHOTONICS_DPI_STANDALONE=1 \
	  -shared -fPIC -o $@ $(SRC) $(LDLIBS)

# The unit tests link the model against their own sv_ring_event stub, so they
# are a normal self-contained executable. Built WITHOUT the simulator include
# path on purpose: it proves the C model needs no DPI headers to be exercised.
$(TEST_BIN): $(SRC) $(HDR) $(TEST_SRC)
	$(CC) $(CFLAGS) -I. -o $@ $(SRC) $(TEST_SRC) $(LDLIBS)

test: $(TEST_BIN)
	./$(TEST_BIN)

# Same suite under ASan + UBSan. This is the only thing that checks the MEMORY
# contract of the ABI rather than the physics: leak detection is what makes
# photonics_ring_free's body load-bearing (as a no-op it passes `make test`),
# and ASan is what would catch a use-after-free of a handle the DV released.
$(ASAN_BIN): $(SRC) $(HDR) $(TEST_SRC)
	$(CC) $(CSTD) $(WARN) -O1 $(SAN_FLAGS) -I. -o $@ $(SRC) $(TEST_SRC) $(LDLIBS)

test-asan: $(ASAN_BIN)
	ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 \
	UBSAN_OPTIONS=print_stacktrace=1 \
	./$(ASAN_BIN)

info:
	@echo "CC          = $(CC)"
	@$(CC) --version | head -1
	@echo "CFLAGS      = $(CFLAGS)"
	@echo "sim lib     = $(LIB)   (sv_ring_event UNDEFINED -- simulator only)"
	@echo "standalone  = $(SALIB) (stub sv_ring_event -- dlopen/ctypes)"
ifneq ($(SVDPI_DIR),)
	@echo "svdpi.h     = $(SVDPI_DIR)/svdpi.h (found)"
else
	@echo "svdpi.h     = not found -- building plain C (this is fine)"
endif

clean:
	rm -f $(LIB) $(SALIB) $(TEST_BIN) $(ASAN_BIN) *.o test/*.o
