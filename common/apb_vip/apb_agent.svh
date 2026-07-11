// -----------------------------------------------------------------------------
// apb_agent.svh : reusable APB3 master agent (monitor always; driver+sequencer
//                 when active) with an attached coverage collector.
//
//  ====================  config_db KEYS  ====================================
//  The TB / env MUST set, targeting this agent's instance path:
//    uvm_config_db#(virtual apb_if)::set(ctxt, "<path>.<agent>", "apb_vif", ifc);
//  The TB / env MAY set (else defaults: ACTIVE, 10000ns timeout, cov on):
//    uvm_config_db#(apb_config)::set(ctxt, "<path>.<agent>", "apb_config", cfg);
//
//  Set internally by this agent for its children (do NOT set these yourself):
//    "vif"        (virtual apb_if.m_drv_mp)  -> apb_driver
//    "vif"        (virtual apb_if.m_mon_mp)  -> apb_monitor
//    "apb_config" (apb_config)               -> whole sub-tree (driver, coverage)
//  =========================================================================
// -----------------------------------------------------------------------------
`ifndef APB_AGENT_SVH
`define APB_AGENT_SVH

class apb_agent extends uvm_agent;
  `uvm_component_utils(apb_agent)

  apb_driver     drv;
  apb_monitor    mon;
  apb_sequencer  seqr;
  apb_coverage   cov;

  apb_config       cfg;
  virtual apb_if   apb_vif;

  function new(string name="apb_agent", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Configuration: fetch or default, then publish to the sub-tree.
    if (!uvm_config_db#(apb_config)::get(this, "", "apb_config", cfg)) begin
      cfg = apb_config::type_id::create("cfg");
      `uvm_info("APB_AGENT", "no apb_config in config_db; using defaults (ACTIVE)",
                UVM_MEDIUM)
    end
    uvm_config_db#(apb_config)::set(this, "*", "apb_config", cfg);

    // Virtual interface: one handle in, modport handles pushed to children.
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", apb_vif))
      `uvm_fatal("APB_AGENT_NOVIF",
                 "virtual apb_if 'apb_vif' not set for agent")
    uvm_config_db#(virtual apb_if.m_mon_mp)::set(this, "apb_monitor", "vif", apb_vif);

    // Monitor + coverage: always present (passive-friendly).
    mon = apb_monitor::type_id::create("apb_monitor", this);
    if (cfg.coverage_enable)
      cov = apb_coverage::type_id::create("apb_coverage", this);

    // Driver + sequencer: only when active.
    if (cfg.is_active == UVM_ACTIVE) begin
      uvm_config_db#(virtual apb_if.m_drv_mp)::set(this, "apb_driver", "vif", apb_vif);
      drv  = apb_driver::type_id::create("apb_driver", this);
      seqr = apb_sequencer::type_id::create("apb_sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cov != null)
      mon.mon_analysis_port.connect(cov.analysis_export);
    if (cfg.is_active == UVM_ACTIVE) begin
      drv.seq_item_port.connect(seqr.seq_item_export);
      `uvm_info("APB_AGENT", "connected driver <-> sequencer", UVM_LOW)
    end
  endfunction

endclass

`endif // APB_AGENT_SVH
