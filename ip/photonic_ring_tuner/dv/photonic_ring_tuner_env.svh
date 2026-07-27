// -----------------------------------------------------------------------------
// photonic_ring_tuner_env.svh : top-level env for the photonic_ring_tuner IP.
//
//   Components:
//     m_apb_agent  : reused APB VIP agent (ACTIVE) -> register stimulus + monitor
//     m_scoreboard : optical-loop scoreboard (spec 7.5) - snoops the APB stream
//                    and samples ring_if once per posedge
//     m_coverage   : tuner functional coverage (spec 7.6)
//     m_predictor  : EXPLICIT uvm_reg_predictor -> RAL mirror from bus traffic
//     m_adapter    : reused apb_reg_adapter
//
//   There is NO optical AGENT: the ring is not driven with transactions, it is
//   CONFIGURED (ring_cfg -> ring_if) and then it drives itself, because the
//   DUT's adc_code input is a function of its own dac_code output through
//   ring_model. The "sequence" is the physics.
//
//   RAL wiring (connect_phase):
//     default_map.set_sequencer(apb seqr, adapter); set_auto_predict(0);
//     apb monitor -> predictor.bus_in  (explicit prediction, no auto-predict)
//
//   config_db expected (set by the test):
//     "env.m_apb_agent"  "apb_vif"  (virtual apb_if)   [agent contract]
//     "env.m_scoreboard" "ring_vif" (virtual ring_if)
//     "env"              "env_cfg"  (photonic_ring_tuner_env_cfg)
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_ENV_SVH
`define PHOTONIC_RING_TUNER_ENV_SVH

class photonic_ring_tuner_env extends uvm_env;
  `uvm_component_utils(photonic_ring_tuner_env)

  photonic_ring_tuner_env_cfg       m_cfg;

  apb_agent                         m_apb_agent;
  photonic_ring_tuner_scoreboard    m_scoreboard;
  photonic_ring_tuner_coverage      m_coverage;

  uvm_reg_predictor #(apb_seq_item) m_predictor;
  apb_reg_adapter                   m_adapter;

  function new(string name = "photonic_ring_tuner_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(photonic_ring_tuner_env_cfg)::get(this, "", "env_cfg", m_cfg))
      `uvm_fatal("ENV_NOCFG", "photonic_ring_tuner_env_cfg 'env_cfg' not set")

    // Publish the APB agent config to the agent (vif set by the test).
    if (m_cfg.m_apb_cfg != null)
      uvm_config_db#(apb_config)::set(this, "m_apb_agent", "apb_config", m_cfg.m_apb_cfg);

    m_apb_agent = apb_agent::type_id::create("m_apb_agent", this);
    m_adapter   = apb_reg_adapter::type_id::create("m_adapter");

    if (m_cfg.reg_block != null)
      m_predictor = uvm_reg_predictor#(apb_seq_item)::type_id::create("m_predictor", this);

    if (m_cfg.en_scoreboard) begin
      // The scoreboard needs the env config for the expected outcome, the
      // deadline margin and the ring description it reports.
      uvm_config_db#(photonic_ring_tuner_env_cfg)::set(this, "m_scoreboard",
                                                       "env_cfg", m_cfg);
      m_scoreboard = photonic_ring_tuner_scoreboard::type_id::create("m_scoreboard", this);
    end

    if (m_cfg.en_coverage)
      m_coverage = photonic_ring_tuner_coverage::type_id::create("m_coverage", this);
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

    // ---- scoreboard : APB register traffic (the optical side comes straight
    //      from ring_if, sampled per clock) ----
    if (m_cfg.en_scoreboard)
      m_apb_agent.mon.mon_analysis_port.connect(m_scoreboard.apb_fifo.analysis_export);

    // ---- coverage : APB stream + the scoreboard's acquisition result ----
    if (m_cfg.en_coverage) begin
      m_coverage.cov_enable = 1'b1;
      m_apb_agent.mon.mon_analysis_port.connect(m_coverage.apb_imp);
      if (m_cfg.en_scoreboard)
        m_scoreboard.acq_ap.connect(m_coverage.acq_imp);
    end
  endfunction

endclass

`endif // PHOTONIC_RING_TUNER_ENV_SVH
