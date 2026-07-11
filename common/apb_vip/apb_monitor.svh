// -----------------------------------------------------------------------------
// apb_monitor.svh : passive APB observer.
//   Samples through the m_mon_cb clocking block. On a completed ACCESS beat
//   (psel && penable && pready) it CREATES A FRESH item, populates
//   addr/dir/wdata/rdata/slverr, and broadcasts it. A new object per beat is
//   mandatory so downstream subscribers (scoreboard, coverage) each get their
//   own transaction instead of a shared, overwritten handle.
// -----------------------------------------------------------------------------
`ifndef APB_MONITOR_SVH
`define APB_MONITOR_SVH

class apb_monitor extends uvm_monitor;
  `uvm_component_utils(apb_monitor)

  virtual apb_if.m_mon_mp            vif;
  uvm_analysis_port #(apb_seq_item)  mon_analysis_port;

  function new(string name="apb_monitor", uvm_component parent=null);
    super.new(name, parent);
    mon_analysis_port = new("mon_analysis_port", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if.m_mon_mp)::get(this, "", "vif", vif))
      `uvm_fatal("APB_MON_NOVIF",
                 "virtual interface 'vif' (m_mon_mp) not set for monitor")
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    forever begin
      @(vif.m_mon_cb);
      // A completing beat while out of reset. Xs during reset make this false.
      if (vif.rst_n === 1'b1 &&
          vif.m_mon_cb.psel && vif.m_mon_cb.penable && vif.m_mon_cb.pready) begin
        apb_seq_item tr = apb_seq_item::type_id::create("mon_item");
        tr.addr   = vif.m_mon_cb.paddr;
        tr.dir    = vif.m_mon_cb.pwrite ? APB_WRITE : APB_READ;
        tr.wdata  = vif.m_mon_cb.pwdata;
        tr.rdata  = vif.m_mon_cb.prdata;
        tr.slverr = vif.m_mon_cb.pslverr;
        `uvm_info("APB_MON", tr.convert2string(), UVM_HIGH)
        mon_analysis_port.write(tr);
      end
    end
  endtask

endclass

`endif // APB_MONITOR_SVH
