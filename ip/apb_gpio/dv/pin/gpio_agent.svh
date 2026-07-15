// -----------------------------------------------------------------------------
// gpio_agent.svh : ACTIVE pin agent (driver + sequencer + monitor).
//   Fetches the virtual gpio_if from config_db under key "gpio_vif" and
//   republishes it to its children under key "vif" (mirrors the apb_agent /
//   timer_irq_agent style). Unlike the passive irq agent, this agent drives
//   gpio_in, so it builds a driver + sequencer when active.
// -----------------------------------------------------------------------------
`ifndef GPIO_AGENT_SVH
`define GPIO_AGENT_SVH

class gpio_agent extends uvm_agent;
  `uvm_component_utils(gpio_agent)

  gpio_driver                 drv;
  gpio_monitor                mon;
  uvm_sequencer #(gpio_item)  seqr;
  virtual gpio_if             vif;

  function new(string name = "gpio_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    is_active = UVM_ACTIVE;   // this agent drives the external pins
    if (!uvm_config_db#(virtual gpio_if)::get(this, "", "gpio_vif", vif))
      `uvm_fatal("GPIO_AGENT_NOVIF", "virtual gpio_if 'gpio_vif' not set for agent")
    uvm_config_db#(virtual gpio_if)::set(this, "mon", "vif", vif);

    mon = gpio_monitor::type_id::create("mon", this);

    if (is_active == UVM_ACTIVE) begin
      uvm_config_db#(virtual gpio_if)::set(this, "drv", "vif", vif);
      drv  = gpio_driver::type_id::create("drv", this);
      seqr = uvm_sequencer#(gpio_item)::type_id::create("seqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction

endclass

`endif // GPIO_AGENT_SVH
