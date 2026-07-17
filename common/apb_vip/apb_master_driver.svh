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
//       hang if the slave never asserts pready. rsp_timeout_ns == 0 disables it.
//     * Fail-safe abort: a transfer killed by reset/timeout never reports
//       success (see xfer_ok below).
//   item_done() returns with rdata/slverr written into req so RAL front-door
//   reads work (provides_responses=0 in the adapter).
// -----------------------------------------------------------------------------
`ifndef APB_MASTER_DRIVER_SVH
`define APB_MASTER_DRIVER_SVH

class apb_driver extends uvm_driver #(apb_seq_item);
  `uvm_component_utils(apb_driver)

  virtual apb_if vif;
  apb_config     cfg;
  int unsigned   rsp_timeout_ns = 10000;

  // Set only when drive_transfer() runs to completion (response captured).
  // Cleared before every fork so an abort (reset / timeout) is distinguishable
  // from a real completion: see run_phase.
  bit            xfer_ok;

  function new(string name="apb_driver", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("APB_DRV_NOVIF",
                 "virtual interface 'vif' (virtual apb_if) not set for driver")
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

    // LAST statement: reaching here means the response above is real. If the
    // fork in run_phase kills this task earlier, xfer_ok stays 0.
    xfer_ok = 1'b1;
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

      xfer_ok = 1'b0;          // cleared before every attempt (see below)

      fork : xfer
        drive_transfer(req);
        begin : reset_abort
          // LEVEL-sensitive, not @(negedge): get_next_item() above blocks for an
          // unbounded time, so reset may already be asserted when this fork
          // starts. An edge-triggered wait would miss it and let the driver
          // drive a full transfer through reset.
          wait (vif.rst_n !== 1'b1);
          `uvm_warning("APB_DRV_RST",
            "Reset asserted mid-transfer; dropping current APB transfer")
        end
        begin : xfer_timeout
          if (rsp_timeout_ns > 0) begin
            #(1ns * rsp_timeout_ns);
            `uvm_error("APB_DRV_TIMEOUT", $sformatf(
              "Slave did not complete transfer (pready) within %0d ns", rsp_timeout_ns))
          end
          else begin
            wait (0);          // rsp_timeout_ns == 0 => timeout disabled
          end
        end
      join_any
      disable fork;

      // An aborted transfer (reset or timeout) never reached the response
      // capture in drive_transfer, so req still holds its untouched defaults
      // (rdata=0, slverr=0). The adapter sets provides_responses=0, so
      // uvm_reg_map calls bus2reg on THIS request object: leaving slverr=0
      // would map the abort to UVM_IS_OK + data=0 and the RAL would fail open.
      // Forcing slverr=1 makes bus2reg map it to UVM_NOT_OK.
      if (!xfer_ok) begin
        req.slverr = 1'b1;     // aborted/timed-out transfer must surface as an error
        req.rdata  = '0;
      end

      drive_idle();            // ensure bus is idle after normal/aborted transfer
      seq_item_port.item_done();
    end
  endtask

endclass

`endif // APB_MASTER_DRIVER_SVH
