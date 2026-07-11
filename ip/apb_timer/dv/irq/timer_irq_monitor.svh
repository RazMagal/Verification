// -----------------------------------------------------------------------------
// timer_irq_monitor.svh : passive monitor on the irq line.
//   Samples irq every posedge through the mon_cb clocking block. It counts
//   posedges from t=0 (in lockstep with the reference model) and, on a level
//   CHANGE, broadcasts a timer_irq_item carrying the new level, rose/fell and
//   the cycle stamp. No item is produced when the level is unchanged.
// -----------------------------------------------------------------------------
`ifndef TIMER_IRQ_MONITOR_SVH
`define TIMER_IRQ_MONITOR_SVH

class timer_irq_monitor extends uvm_monitor;
  `uvm_component_utils(timer_irq_monitor)

  virtual timer_irq_if               vif;
  uvm_analysis_port #(timer_irq_item) ap;

  function new(string name = "timer_irq_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual timer_irq_if)::get(this, "", "vif", vif))
      `uvm_fatal("IRQ_MON_NOVIF", "virtual timer_irq_if 'vif' not set for monitor")
  endfunction

  task run_phase(uvm_phase phase);
    bit          prev = 1'b0;
    bit          cur;
    int unsigned cyc  = 0;
    super.run_phase(phase);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin
        prev = 1'b0;                 // irq is 0 in reset; re-baseline
        cyc++;
        continue;
      end
      cur = vif.mon_cb.irq;
      if (cur !== prev) begin
        timer_irq_item it = timer_irq_item::type_id::create("irq_act");
        it.irq    = cur;
        it.rose   = cur & ~prev;
        it.fell   = ~cur & prev;
        it.cyc    = cyc;
        it.tstamp = $time;
        `uvm_info("IRQ_MON", it.convert2string(), UVM_HIGH)
        ap.write(it);
      end
      prev = cur;
      cyc++;
    end
  endtask

endclass

`endif // TIMER_IRQ_MONITOR_SVH
