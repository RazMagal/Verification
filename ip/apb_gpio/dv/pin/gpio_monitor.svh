// -----------------------------------------------------------------------------
// gpio_monitor.svh : passive monitor on the pin side.
//   Samples gpio_in/out/oe/irq every posedge through mon_cb, counting posedges
//   from t=0 (in lockstep with the reference model). On a CHANGE of any observed
//   DUT output (gpio_out, gpio_oe, irq) it broadcasts a gpio_mon_item snapshot
//   with the current values + cycle stamp. No item is produced when nothing
//   changed. Outputs are 0 in reset, so prev is re-baselined to 0 there.
// -----------------------------------------------------------------------------
`ifndef GPIO_MONITOR_SVH
`define GPIO_MONITOR_SVH

class gpio_monitor extends uvm_monitor;
  `uvm_component_utils(gpio_monitor)

  virtual gpio_if                    vif;
  uvm_analysis_port #(gpio_mon_item) ap;

  function new(string name = "gpio_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual gpio_if)::get(this, "", "vif", vif))
      `uvm_fatal("GPIO_MON_NOVIF", "virtual gpio_if 'vif' not set for monitor")
  endfunction

  task run_phase(uvm_phase phase);
    bit [APB_GPIO_NUM_PINS-1:0] prev_out = '0;
    bit [APB_GPIO_NUM_PINS-1:0] prev_oe  = '0;
    bit                      prev_irq = 1'b0;
    bit [APB_GPIO_NUM_PINS-1:0] c_out, c_oe, c_in;
    bit                      c_irq;
    int unsigned             cyc = 0;
    super.run_phase(phase);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin
        prev_out = '0; prev_oe = '0; prev_irq = 1'b0;   // re-baseline in reset
        cyc++;
        continue;
      end
      c_out = vif.mon_cb.gpio_out;
      c_oe  = vif.mon_cb.gpio_oe;
      c_irq = vif.mon_cb.irq;
      c_in  = vif.mon_cb.gpio_in;
      if ((c_out !== prev_out) || (c_oe !== prev_oe) || (c_irq !== prev_irq)) begin
        gpio_mon_item it = gpio_mon_item::type_id::create("pin_act");
        it.gpio_out = c_out;
        it.gpio_oe  = c_oe;
        it.irq      = c_irq;
        it.gpio_in  = c_in;
        it.cyc      = cyc;
        it.tstamp   = $time;
        `uvm_info("GPIO_MON", it.convert2string(), UVM_HIGH)
        ap.write(it);
      end
      prev_out = c_out;
      prev_oe  = c_oe;
      prev_irq = c_irq;
      cyc++;
    end
  endtask

endclass

`endif // GPIO_MONITOR_SVH
