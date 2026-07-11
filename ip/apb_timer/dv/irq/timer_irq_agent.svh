// -----------------------------------------------------------------------------
// timer_irq_agent.svh : always-passive agent wrapping the irq monitor.
//   Fetches the virtual timer_irq_if from config_db under key "irq_vif" and
//   republishes it to the monitor under key "vif" (mirrors the apb_agent style).
//   No sequencer/driver: the irq line is DUT-driven only.
// -----------------------------------------------------------------------------
`ifndef TIMER_IRQ_AGENT_SVH
`define TIMER_IRQ_AGENT_SVH

class timer_irq_agent extends uvm_agent;
  `uvm_component_utils(timer_irq_agent)

  timer_irq_monitor  mon;
  virtual timer_irq_if vif;

  function new(string name = "timer_irq_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    is_active = UVM_PASSIVE;   // irq is observe-only
    if (!uvm_config_db#(virtual timer_irq_if)::get(this, "", "irq_vif", vif))
      `uvm_fatal("IRQ_AGENT_NOVIF", "virtual timer_irq_if 'irq_vif' not set for agent")
    uvm_config_db#(virtual timer_irq_if)::set(this, "mon", "vif", vif);
    mon = timer_irq_monitor::type_id::create("mon", this);
  endfunction

endclass

`endif // TIMER_IRQ_AGENT_SVH
