// -----------------------------------------------------------------------------
// apb_subsystem_env_cfg.svh : top configuration object for the subsystem env.
//   Created by the test, passed to the env via config_db (key "env_cfg"). Holds:
//     * m_top_cfg    : reused apb_config for the ACTIVE upstream agent
//     * m_timer_cfg  : reused apb_config[2] for the PASSIVE per-timer agents
//     * reg_block    : the hierarchical RAL model (built + locked by the test)
//     * knobs        : scoreboard / coverage / build-timer-sub-envs enables
//   The env turns each m_timer_cfg[i] into an apb_timer_env_cfg (with reg_block
//   left null) so each reused apb_timer_env nests as a passive checking block.
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_ENV_CFG_SVH
`define APB_SUBSYSTEM_ENV_CFG_SVH

class apb_subsystem_env_cfg extends uvm_object;
  `uvm_object_utils(apb_subsystem_env_cfg)

  // Reused VIP agent configs.
  apb_config m_top_cfg;         // upstream, ACTIVE (drives all stimulus)
  apb_config m_timer_cfg[2];    // per-timer local buses, PASSIVE (monitor only)

  // Hierarchical RAL model.
  apb_subsystem_reg_block reg_block;

  // Env knobs.
  bit en_scoreboard = 1'b1;     // subsystem + per-timer scoreboards
  bit en_coverage   = 1'b1;     // subsystem + per-timer coverage
  bit en_timer_env  = 1'b1;     // build the two passive apb_timer sub-envs

  function new(string name = "apb_subsystem_env_cfg");
    super.new(name);
  endfunction

endclass

`endif // APB_SUBSYSTEM_ENV_CFG_SVH
