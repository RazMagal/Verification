// -----------------------------------------------------------------------------
// apb_vip_pkg.sv : compilation package for the reusable APB3 master VIP.
//
//   Compile order (this file compiles the classes; the interface and SVA are
//   compiled SEPARATELY at $unit, since they cannot live inside a package):
//     1) common/apb_vip/apb_if.sv        <-- interface, compile BEFORE this pkg
//     2) common/apb_vip/apb_vip_pkg.sv   <-- this file
//     3) common/apb_vip/apb_checker.sv   <-- SVA module (owned elsewhere), $unit
//
//   The .svh files below are included in strict dependency order:
//     params -> config -> seq_item -> reg_adapter -> coverage
//            -> monitor -> driver -> sequencer -> agent -> seqlib
// -----------------------------------------------------------------------------
package apb_vip_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "apb_params.svh"
  `include "apb_config.svh"
  `include "apb_seq_item.svh"
  `include "apb_reg_adapter.svh"
  `include "apb_coverage.svh"
  `include "apb_monitor.svh"
  `include "apb_master_driver.svh"
  `include "apb_sequencer.svh"
  `include "apb_agent.svh"
  `include "apb_seqlib.svh"

endpackage : apb_vip_pkg
