// -----------------------------------------------------------------------------
// apb_gpio_pkg.sv : compilation package for the apb_gpio UVM DV env.
//   Compile AFTER apb_vip_pkg (imported below) and AFTER the interfaces
//   (apb_if.sv, gpio_if.sv) which live at $unit, not in a package.
//   Includes are in strict dependency order.
// -----------------------------------------------------------------------------
package apb_gpio_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import apb_vip_pkg::*;

  // RAL + config
  `include "apb_gpio_reg_block.svh"
  `include "apb_gpio_env_cfg.svh"

  // pin agent (item -> driver -> monitor -> agent)
  `include "gpio_item.svh"
  `include "gpio_driver.svh"
  `include "gpio_monitor.svh"
  `include "gpio_agent.svh"

  // reference model (defines apb_gpio_evt_item) -> scoreboard -> coverage
  `include "apb_gpio_ref_model.svh"
  `include "apb_gpio_scoreboard.svh"
  `include "apb_gpio_coverage.svh"

  // environment
  `include "apb_gpio_env.svh"

  // sequences + tests
  `include "apb_gpio_vseq_lib.svh"
  `include "apb_gpio_test_lib.svh"

endpackage : apb_gpio_pkg
