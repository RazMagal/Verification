// -----------------------------------------------------------------------------
// apb_master_driver.svh : protocol-correct, reset-hardened APB3 master driver.
//   One seq_item == one full transfer. Proven SETUP->ACCESS sequencing kept:
//     SETUP  : psel=1, penable=0, addr/pwrite/wdata driven
//     ACCESS : psel=1, penable=1
//     wait   : advance until m_drv_cb.pready==1 (tolerates >0 wait states)
//     done   : capture prdata/pslverr back into the req, deassert (idle)
//   Hardening added:
//     * Reset-aware: holds the bus idle during reset; a reset mid-transfer
//       aborts the current transfer via fork/disable and the loop recovers.
//     * Timeout: rsp_timeout_ns (from apb_config) => uvm_error instead of a
//       hang if the slave never asserts pready.
//   item_done() returns with rdata/slverr written into req so RAL front-door
//   reads work (provides_responses=0 in the adapter).
// -----------------------------------------------------------------------------
`ifndef APB_MASTER_DRIVER_SVH
`define APB_MASTER_DRIVER_SVH

class apb_driver extends uvm_driver #(apb_seq_item);
  `uvm_component_utils(apb_driver)

  virtual apb_if.m_drv_mp vif;
  apb_config              cfg;
  int unsigned            rsp_timeout_ns = 10000;

  function new(string name="apb_driver", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if.m_drv_mp)::get(this, "", "vif", vif))
      `uvm_fatal("APB_DRV_NOVIF",
                 "virtual interface 'vif' (m_drv_mp) not set for driver")
    if (uvm_config_db#(apb_config)::get(this, "", "apb_config", cfg))
      rsp_timeout_ns = cfg.rsp_timeout_ns;
  endfunction

  // Park the bus in the APB idle state (deassert psel/penable).
  task drive_idle();
    vif.m_drv_cb.psel    <= 1'b0;
    vif.m_drv_cb.penable <= 1'b0;
    vif.m_drv_cb.pwrite  <= 1'b0;
    vif.m_drv_cb.paddr   <= '0;
    vif.m_drv_cb.pwdata  <= '0;
  endtask

  // One complete APB3 transfer. Writes response fields back into tr.
  task drive_transfer(apb_seq_item tr);
    bit is_write = (tr.dir == APB_WRITE);

    // SETUP phase
    @(vif.m_drv_cb);
    vif.m_drv_cb.psel    <= 1'b1;
    vif.m_drv_cb.penable <= 1'b0;
    vif.m_drv_cb.pwrite  <= is_write;
    vif.m_drv_cb.paddr   <= tr.addr;
    vif.m_drv_cb.pwdata  <= is_write ? tr.wdata : '0;

    // ACCESS phase
    @(vif.m_drv_cb);
    vif.m_drv_cb.penable <= 1'b1;

    // Wait for the slave to be ready (tolerate wait states).
    do @(vif.m_drv_cb); while (vif.m_drv_cb.pready !== 1'b1);

    // Capture response on the completing beat.
    tr.rdata  = vif.m_drv_cb.prdata;
    tr.slverr = vif.m_drv_cb.pslverr;

    // Return to idle at this same edge (penable deasserts next cycle).
    drive_idle();
  endtask

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    drive_idle();
    forever begin
      // Keep the bus idle while reset is asserted (active-low).
      while (vif.rst_n !== 1'b1) begin
        drive_idle();
        @(vif.m_drv_cb);
      end

      seq_item_port.get_next_item(req);

      fork : xfer
        drive_transfer(req);
        begin : reset_abort
          @(negedge vif.rst_n);
          `uvm_warning("APB_DRV_RST",
            "Reset asserted mid-transfer; dropping current APB transfer")
        end
        begin : xfer_timeout
          #(1ns * rsp_timeout_ns);
          `uvm_error("APB_DRV_TIMEOUT", $sformatf(
            "Slave did not complete transfer (pready) within %0d ns", rsp_timeout_ns))
        end
      join_any
      disable fork;

      drive_idle();            // ensure bus is idle after normal/aborted transfer
      seq_item_port.item_done();
    end
  endtask

endclass

`endif // APB_MASTER_DRIVER_SVH
