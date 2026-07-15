// -----------------------------------------------------------------------------
// apb_gpio_env_cfg.svh : top-level configuration object for the gpio env.
//   Created by the test, passed to the env via config_db (key "env_cfg").
//   Holds the reused APB agent config, the RAL block handle, and knobs to
//   enable/disable the scoreboard and functional coverage.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_ENV_CFG_SVH
`define APB_GPIO_ENV_CFG_SVH

class apb_gpio_env_cfg extends uvm_object;
  `uvm_object_utils(apb_gpio_env_cfg)

  // Reused VIP agent configuration (is_active, timeout, coverage_enable).
  apb_config         m_apb_cfg;

  // RAL model (created + built + locked by the test).
  apb_gpio_reg_block reg_block;

  // Env knobs.
  bit en_scoreboard = 1'b1;
  bit en_coverage   = 1'b1;

  function new(string name = "apb_gpio_env_cfg");
    super.new(name);
  endfunction

endclass

`endif // APB_GPIO_ENV_CFG_SVH
