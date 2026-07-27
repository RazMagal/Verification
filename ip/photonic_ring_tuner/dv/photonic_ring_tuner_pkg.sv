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
