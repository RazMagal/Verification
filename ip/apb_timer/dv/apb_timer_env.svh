// -----------------------------------------------------------------------------
// apb_timer_env.svh : top-level env for the apb_timer IP.
//
//   Components:
//     m_apb_agent  : reused APB VIP agent (ACTIVE)  -> stimulus + monitor
//     m_irq_agent  : passive irq agent               -> irq-line monitor
//     m_ref_model  : cycle-accurate predictor (samples apb_if directly)
//     m_scoreboard : reference-model scoreboard (APB + IRQ, paired fifos)
//     m_coverage   : timer functional coverage
//     m_predictor  : EXPLICIT uvm_reg_predictor -> RAL mirror from bus traffic
//     m_adapter    : reused apb_reg_adapter
//
//   RAL wiring (connect_phase):
//     default_map.set_sequencer(apb seqr, adapter); set_auto_predict(0);
//     apb monitor -> predictor.bus_in  (explicit prediction, no auto-predict)
//
//   config_db expected (set by the test):
//     "env.m_apb_agent" "apb_vif" (virtual apb_if)          [agent contract]
//     "env.m_ref_model" "vif"     (virtual apb_if)
//     "env.m_irq_agent" "irq_vif" (virtual timer_irq_if)
//     "env"             "env_cfg" (apb_timer_env_cfg)
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_ENV_SVH
`define APB_TIMER_ENV_SVH

class apb_timer_env extends uvm_env;
  `uvm_component_utils(apb_timer_env)

  apb_timer_env_cfg               m_cfg;

  apb_agent                       m_apb_agent;
  timer_irq_agent                 m_irq_agent;
  apb_timer_ref_model             m_ref_model;
  apb_timer_scoreboard            m_scoreboard;
  apb_timer_coverage              m_coverage;

  uvm_reg_predictor #(apb_seq_item) m_predictor;
  apb_reg_adapter                 m_adapter;

  function new(string name = "apb_timer_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(apb_timer_env_cfg)::get(this, "", "env_cfg", m_cfg))
      `uvm_fatal("ENV_NOCFG", "apb_timer_env_cfg 'env_cfg' not set")

    // Publish the APB agent config to the agent (vif set by the test).
    if (m_cfg.m_apb_cfg != null)
      uvm_config_db#(apb_config)::set(this, "m_apb_agent", "apb_config", m_cfg.m_apb_cfg);

    m_apb_agent = apb_agent::type_id::create("m_apb_agent", this);
    m_irq_agent = timer_irq_agent::type_id::create("m_irq_agent", this);
    m_ref_model = apb_timer_ref_model::type_id::create("m_ref_model", this);
    m_adapter   = apb_reg_adapter::type_id::create("m_adapter");

    if (m_cfg.reg_block != null)
      m_predictor = uvm_reg_predictor#(apb_seq_item)::type_id::create("m_predictor", this);

    if (m_cfg.en_scoreboard)
      m_scoreboard = apb_timer_scoreboard::type_id::create("m_scoreboard", this);

    if (m_cfg.en_coverage)
      m_coverage = apb_timer_coverage::type_id::create("m_coverage", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // ---- RAL : front-door sequencer + explicit predictor ----
    if (m_cfg.reg_block != null) begin
      m_cfg.reg_block.default_map.set_sequencer(m_apb_agent.seqr, m_adapter);
      m_cfg.reg_block.default_map.set_auto_predict(0);   // predictor does it
      m_predictor.map     = m_cfg.reg_block.default_map;
      m_predictor.adapter = m_adapter;
      m_apb_agent.mon.mon_analysis_port.connect(m_predictor.bus_in);
    end

    // ---- scoreboard : expected (ref model) vs actual (monitors) ----
    if (m_cfg.en_scoreboard) begin
      m_ref_model.apb_exp_ap.connect(m_scoreboard.apb_exp_fifo.analysis_export);
      m_apb_agent.mon.mon_analysis_port.connect(m_scoreboard.apb_act_fifo.analysis_export);
      m_ref_model.irq_exp_ap.connect(m_scoreboard.irq_exp_fifo.analysis_export);
      m_irq_agent.mon.ap.connect(m_scoreboard.irq_act_fifo.analysis_export);
    end

    // ---- coverage : APB stream + reference-model timer events ----
    if (m_cfg.en_coverage) begin
      m_coverage.cov_enable = 1'b1;
      m_apb_agent.mon.mon_analysis_port.connect(m_coverage.apb_imp);
      m_ref_model.evt_ap.connect(m_coverage.evt_imp);
    end
  endfunction

endclass

`endif // APB_TIMER_ENV_SVH
