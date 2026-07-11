// -----------------------------------------------------------------------------
// apb_timer_pkg.sv : compilation package for the apb_timer UVM DV env.
//   Compile AFTER apb_vip_pkg (imported below) and AFTER the interfaces
//   (apb_if.sv, timer_irq_if.sv) which live at $unit, not in a package.
//   Includes are in strict dependency order.
// -----------------------------------------------------------------------------
package apb_timer_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import apb_vip_pkg::*;

  // RAL + config
  `include "apb_timer_reg_block.svh"
  `include "apb_timer_env_cfg.svh"

  // IRQ agent (item -> monitor -> agent)
  `include "timer_irq_item.svh"
  `include "timer_irq_monitor.svh"
  `include "timer_irq_agent.svh"

  // reference model (defines apb_timer_evt_item) -> scoreboard -> coverage
  `include "apb_timer_ref_model.svh"
  `include "apb_timer_scoreboard.svh"
  `include "apb_timer_coverage.svh"

  // environment
  `include "apb_timer_env.svh"

  // sequences + tests
  `include "apb_timer_vseq_lib.svh"
  `include "apb_timer_test_lib.svh"

endpackage : apb_timer_pkg
