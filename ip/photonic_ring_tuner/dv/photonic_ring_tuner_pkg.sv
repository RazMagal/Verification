// -----------------------------------------------------------------------------
// photonic_ring_tuner_pkg.sv : compilation package for the tuner UVM DV env.
//   Compile AFTER apb_vip_pkg (imported below) and AFTER the interfaces
//   (apb_if.sv, ring_if.sv) which live at $unit, not in a package.
//   Includes are in strict dependency order.
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
