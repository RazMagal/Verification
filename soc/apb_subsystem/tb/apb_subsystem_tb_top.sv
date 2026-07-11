// -----------------------------------------------------------------------------
// apb_subsystem_tb_top.sv : top module for the apb_subsystem UVM environment.
//
//   - 10ns clock + async-assert / sync-deassert active-low reset + a watchdog
//   - the 12-bit upstream apb_if (default width = APB_ADDR_W = 12 in this build)
//   - the DUT apb_subsystem (apb.slave, irq0, irq1)
//   - two passive timer_irq_if, one per timer irq output, for the reused IRQ
//     monitors
//   - BINDS the reusable SVA:
//       * apb_protocol_checker onto apb_if -> applies to ALL apb_if instances:
//         the upstream u_apb_if AND the three INTERNAL buses (t0_if/t1_if/mem_if),
//         so APB protocol is checked everywhere in the fabric.
//       * apb_timer_sva onto apb_timer   -> applies to BOTH timer instances.
//     (exact port maps taken from each SVA file's header comment.)
//   - sets the vifs into config_db (the tb owns the hierarchical refs to the
//     internal buses u_dut.t0_if / u_dut.t1_if) then run_test().
//
//   Compile note (see sim/run.f): +define+APB_ADDR_W=12 so every apb_if instance
//   and the VIP's unparameterized `virtual apb_if` handles are all 12-bit.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module apb_subsystem_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_vip_pkg::*;
  import apb_timer_pkg::*;
  import apb_subsystem_pkg::*;

  // ---- clock / reset ----
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk;                       // 100 MHz

  initial begin
    rst_n = 1'b0;                             // async assert at t=0
    repeat (5) @(posedge clk);                // hold a few cycles
    #1 rst_n = 1'b1;                          // sync deassert (just after an edge)
  end

  // ---- upstream interface (12-bit addr via +define+APB_ADDR_W=12 default) ----
  apb_if u_apb_if ();
  assign u_apb_if.clk   = clk;
  assign u_apb_if.rst_n = rst_n;

  // ---- DUT interrupt wires ----
  logic w_irq0;
  logic w_irq1;

  // ---- DUT ----
  apb_subsystem u_dut (
    .apb  (u_apb_if.slave),
    .irq0 (w_irq0),
    .irq1 (w_irq1)
  );

  // ---- passive irq observation interfaces (one per timer) ----
  timer_irq_if u_irq0 (.clk(clk), .rst_n(rst_n));
  timer_irq_if u_irq1 (.clk(clk), .rst_n(rst_n));
  assign u_irq0.irq = w_irq0;
  assign u_irq1.irq = w_irq1;

  // ---- bind: reusable APB3 protocol checker onto EVERY apb_if instance ----
  // (upstream u_apb_if + internal t0_if/t1_if/mem_if inside u_dut)
  bind apb_if apb_protocol_checker #(
    .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
  ) u_apb_chk (
    .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable),
    .pwrite(pwrite), .pready(pready), .pslverr(pslverr),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata)
  );

  // ---- bind: timer-specific SVA onto BOTH apb_timer instances ----
  bind apb_timer apb_timer_sva #(
    .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
  ) u_timer_sva (
    .clk(apb.clk), .rst_n(apb.rst_n), .irq(irq),
    .irq_en(ctrl_irqen), .status_irq(status_irq), .cnt(cnt),
    .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
    .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
  );

  // ---- config_db : vifs (tb owns the internal-bus hierarchical refs) + run ----
  initial begin
    uvm_config_db#(virtual apb_if)::set(null, "*", "vif_top", u_apb_if);
    uvm_config_db#(virtual apb_if)::set(null, "*", "vif_t0",  u_dut.t0_if);
    uvm_config_db#(virtual apb_if)::set(null, "*", "vif_t1",  u_dut.t1_if);
    uvm_config_db#(virtual timer_irq_if)::set(null, "*", "vif_irq0", u_irq0);
    uvm_config_db#(virtual timer_irq_if)::set(null, "*", "vif_irq1", u_irq1);
    run_test();
  end

  // ---- safety watchdog ----
  initial begin
    #5ms;
    `uvm_fatal("TB_WATCHDOG", "global timeout reached (5ms) - simulation hung")
  end

endmodule
