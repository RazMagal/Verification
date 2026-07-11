// -----------------------------------------------------------------------------
// apb_subsystem_pkg.sv : compilation package for the apb_subsystem UVM DV env.
//
//   Compile AFTER apb_vip_pkg and apb_timer_pkg (imported below), and AFTER the
//   interfaces (apb_if.sv, timer_irq_if.sv) which live at $unit. This package
//   REUSES everything from the two imported packages (the APB VIP agent/adapter/
//   seqlib and the entire apb_timer DV: reg block, ref model, scoreboard, irq
//   agent, timer env) and only adds the thin subsystem-specific composition.
//
//   Includes are in strict dependency order.
// -----------------------------------------------------------------------------
package apb_subsystem_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import apb_vip_pkg::*;     // apb_agent/config/seq_item/sequencer/adapter/seqlib
  import apb_timer_pkg::*;   // apb_timer_reg_block/env/ref_model/scoreboard/irq

  // ---- subsystem DV (dependency order) ----
  `include "apb_subsystem_reg_block.svh"
  `include "apb_subsystem_env_cfg.svh"
  `include "apb_subsystem_coverage.svh"
  `include "apb_subsystem_scoreboard.svh"
  `include "apb_subsystem_virtual_sequencer.svh"
  `include "apb_subsystem_env.svh"

  // ---- sequences + tests ----
  `include "apb_subsystem_vseq_lib.svh"
  `include "apb_subsystem_test_lib.svh"

endpackage : apb_subsystem_pkg
