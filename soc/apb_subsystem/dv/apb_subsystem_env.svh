// -----------------------------------------------------------------------------
// apb_subsystem_env.svh : subsystem UVM env - built almost entirely from reuse.
//
//   Composition:
//     m_top_agent   : reused apb_agent (ACTIVE) on the 12-bit upstream u_apb_if.
//                     Drives ALL stimulus (register, memory, error traffic).
//     m_timer_env0/1: reused apb_timer_env NESTED PASSIVELY (see note below), one
//                     per timer. Each wraps a passive apb_agent (on t{i}_if), the
//                     reused apb_timer_ref_model, apb_timer_scoreboard, the
//                     timer_irq_agent (on irq{i}) and apb_timer_coverage - i.e.
//                     the timer's entire behavioral check, reused verbatim.
//     m_predictor   : uvm_reg_predictor on the ROOT map, fed by the top monitor
//                     (keeps the hierarchical RAL mirror in sync with real
//                     upstream traffic).
//     m_adapter     : reused apb_reg_adapter (front-door bridge).
//     m_scoreboard  : apb_subsystem_scoreboard (decode + memory shadow).
//     m_vseqr       : virtual sequencer holding the top agent's sequencer.
//     m_cov         : apb_subsystem_coverage (page/decode plan).
//
//   WHY NEST apb_timer_env (vs. composing its classes by hand):
//     Setting the timer env_cfg's m_apb_cfg to PASSIVE makes its apb_agent a
//     pure monitor on the internal bus, and setting reg_block = NULL makes the
//     nested env SKIP its own RAL predictor / front-door sequencer setup. What
//     remains - passive apb monitor + ref_model + scoreboard + irq agent +
//     coverage, all pre-wired in the nested connect_phase - is EXACTLY the
//     passive checking block we need, with zero re-plumbing. This reuses more
//     than composing the leaf classes ourselves and cannot drift from the IP.
//     The per-timer ref models are behavioral and independent of the RAL mirror,
//     so the top predictor is the ONLY thing predicting the reg model.
//
//   config_db the env sets for its children:
//     "m_top_agent" "apb_config"  (top ACTIVE cfg)
//     "m_timer_env0"/"m_timer_env1" "env_cfg" (apb_timer_env_cfg, reg_block=null)
//   config_db the TEST must set (child vif contracts):
//     top    : "m_top_agent"           "apb_vif"
//     timer0 : "m_timer_env0.m_apb_agent" "apb_vif" ; ".m_ref_model" "vif" ;
//              ".m_irq_agent" "irq_vif"      (same shape for timer1)
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_ENV_SVH
`define APB_SUBSYSTEM_ENV_SVH

class apb_subsystem_env extends uvm_env;
  `uvm_component_utils(apb_subsystem_env)

  apb_subsystem_env_cfg              m_cfg;

  apb_agent                         m_top_agent;   // ACTIVE upstream
  apb_timer_env                     m_timer_env0;  // passive timer0 checker
  apb_timer_env                     m_timer_env1;  // passive timer1 checker

  uvm_reg_predictor #(apb_seq_item) m_predictor;
  apb_reg_adapter                   m_adapter;
  apb_subsystem_scoreboard          m_scoreboard;
  apb_subsystem_virtual_sequencer   m_vseqr;
  apb_subsystem_coverage            m_cov;

  function new(string name = "apb_subsystem_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(apb_subsystem_env_cfg)::get(this, "", "env_cfg", m_cfg))
      `uvm_fatal("SS_ENV_NOCFG", "apb_subsystem_env_cfg 'env_cfg' not set")

    // ---- TOP active agent (drives everything through the fabric) ----
    if (m_cfg.m_top_cfg != null)
      uvm_config_db#(apb_config)::set(this, "m_top_agent", "apb_config",
                                      m_cfg.m_top_cfg);
    m_top_agent = apb_agent::type_id::create("m_top_agent", this);

    // ---- reused apb_timer envs, nested passively (reg_block=null) ----
    if (m_cfg.en_timer_env) begin
      build_timer_env("m_timer_env0", m_cfg.m_timer_cfg[0], m_timer_env0);
      build_timer_env("m_timer_env1", m_cfg.m_timer_cfg[1], m_timer_env1);
    end

    // ---- RAL glue ----
    m_adapter = apb_reg_adapter::type_id::create("m_adapter");
    if (m_cfg.reg_block != null)
      m_predictor = uvm_reg_predictor#(apb_seq_item)::type_id::create("m_predictor",
                                                                      this);

    // ---- subsystem scoreboard / coverage / vseqr ----
    if (m_cfg.en_scoreboard)
      m_scoreboard = apb_subsystem_scoreboard::type_id::create("m_scoreboard", this);
    if (m_cfg.en_coverage)
      m_cov = apb_subsystem_coverage::type_id::create("m_cov", this);
    m_vseqr = apb_subsystem_virtual_sequencer::type_id::create("m_vseqr", this);
  endfunction

  // Build one nested passive apb_timer_env from a passive apb_config.
  function void build_timer_env(string             inst,
                                apb_config         apb_cfg,
                                ref apb_timer_env  h);
    apb_timer_env_cfg tcfg = apb_timer_env_cfg::type_id::create({inst, "_cfg"});
    if (apb_cfg != null) apb_cfg.is_active = UVM_PASSIVE;  // force monitor-only
    tcfg.m_apb_cfg     = apb_cfg;
    tcfg.reg_block     = null;                 // KEY: disable nested RAL predictor
    tcfg.en_scoreboard = m_cfg.en_scoreboard;  // reuse the timer scoreboard
    tcfg.en_coverage   = m_cfg.en_coverage;    // reuse the timer coverage
    uvm_config_db#(apb_timer_env_cfg)::set(this, inst, "env_cfg", tcfg);
    h = apb_timer_env::type_id::create(inst, this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // ---- RAL : root map front-door + explicit predictor on the top map ----
    if (m_cfg.reg_block != null) begin
      m_cfg.reg_block.default_map.set_sequencer(m_top_agent.seqr, m_adapter);
      m_cfg.reg_block.default_map.set_auto_predict(0);   // predictor mirrors bus
      m_predictor.map     = m_cfg.reg_block.default_map;
      m_predictor.adapter = m_adapter;
      m_top_agent.mon.mon_analysis_port.connect(m_predictor.bus_in);
    end

    // ---- subsystem scoreboard : fed by the top monitor ----
    if (m_cfg.en_scoreboard)
      m_top_agent.mon.mon_analysis_port.connect(m_scoreboard.analysis_export);

    // ---- subsystem coverage : fed by the top monitor ----
    if (m_cfg.en_coverage)
      m_top_agent.mon.mon_analysis_port.connect(m_cov.analysis_export);

    // ---- expose the top sequencer to the virtual sequencer ----
    m_vseqr.top_seqr = m_top_agent.seqr;
  endfunction

endclass

`endif // APB_SUBSYSTEM_ENV_SVH
