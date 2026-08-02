// -----------------------------------------------------------------------------
// photonic_ring_tuner_pkg.sv : compilation package for the tuner UVM DV env.
//   Compile AFTER apb_vip_pkg (imported below) and AFTER the interfaces
//   (apb_if.sv, ring_if.sv) which live at $unit, not in a package.
//   Includes are in strict dependency order.
//
//   With +define+RING_DPI this package additionally imports photonics_dpi_pkg
//   (common/dpi), which must therefore compile BEFORE it -- see sim/run.f.
//   WITHOUT the define nothing here references it at all, so the default flow
//   has no dependency on common/dpi and none on any C library: that is what
//   keeps this environment runnable on EDA Playground, which cannot compile
//   user C. Default flow = no define = pure SystemVerilog.
// -----------------------------------------------------------------------------
package photonic_ring_tuner_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import apb_vip_pkg::*;

  // COMPILE-TIME GEOMETRY FIRST: every width in this package (RAL field widths
  // and their reserved padding, DAC_MAX, the ring_cfg bounds, the deadline, the
  // coverage bin edges) is derived from these parameters, so they must be
  // elaborated before anything below. It is included after the apb_vip_pkg
  // import because TUNER_ADDR_WIDTH is taken from APB_ADDR_WIDTH rather than
  // stated a second time.
  `include "photonic_ring_tuner_params.svh"

`ifdef RING_DPI
  // Needed only by the DPI equivalence vseq/test (version string + the
  // sv_ring_event callback tallies). Imported, not wildcard-exported, so the
  // DPI names stay explicitly qualified at their few use sites.
  import photonics_dpi_pkg::*;
`endif

  // RAL + config (env_cfg defines ring_cfg and the mode/outcome enums)
  `include "photonic_ring_tuner_reg_block.svh"
  `include "photonic_ring_tuner_env_cfg.svh"

  // scoreboard (defines photonic_ring_tuner_acq_item) -> coverage
  `include "photonic_ring_tuner_scoreboard.svh"
  `include "photonic_ring_tuner_coverage.svh"

  // environment
  `include "photonic_ring_tuner_env.svh"

  // sequences + tests
  `include "photonic_ring_tuner_vseq_lib.svh"
  `include "photonic_ring_tuner_test_lib.svh"

endpackage : photonic_ring_tuner_pkg
