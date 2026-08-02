// -----------------------------------------------------------------------------
// apb_timer_tb_top.sv : top module for the apb_timer UVM environment.
//
//   - generates a 10ns clock and an async-assert / sync-deassert active-low reset
//   - instantiates the shared apb_if at its DEFAULT width (`APB_ADDR_W /
//     `APB_DATA_W) plus the passive timer_irq_if; the tb states no width itself
//   - instantiates the DUT (apb.slave modport, irq -> irq_if.irq)
//   - BINDS the reusable protocol checker onto apb_if and the timer SVA onto the
//     DUT (per each checker's header)
//   - sets the vifs into config_db under keys "apb_vif" / "irq_vif" and run_test()
//
//   Compile note: apb_if.sv + timer_irq_if.sv compile at $unit BEFORE the
//   packages; apb_vip_pkg then apb_timer_pkg; then RTL, SVA, this tb (see run.f).
//   apb_if is instantiated WITHOUT parameter overrides on purpose: the VIP's
//   `virtual apb_if` handles are unparameterized, so only the interface defaults
//   are usable, and those come from the same macro apb_timer_params.svh
//   elaborates from (common/apb_vip/apb_width_defines.svh).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module apb_timer_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_vip_pkg::*;
  import apb_timer_pkg::*;

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

  // ---- interfaces (default widths: see the compile note above) ----
  apb_if       u_apb_if ();
  timer_irq_if u_irq_if (.clk(clk), .rst_n(rst_n));

  assign u_apb_if.clk   = clk;
  assign u_apb_if.rst_n = rst_n;

  // ---- DUT (widths from apb_timer_pkg, the same source the RAL uses) ----
  apb_timer #(
    .ADDR_WIDTH (APB_TIMER_ADDR_WIDTH),
    .DATA_WIDTH (APB_TIMER_DATA_WIDTH)
  ) dut (
    .apb (u_apb_if.slave),
    .irq (u_irq_if.irq)
  );

  // ---- bind: reusable APB3 protocol checker onto every apb_if instance ----
  bind apb_if apb_protocol_checker #(
    .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
  ) u_apb_chk (
    .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable),
    .pwrite(pwrite), .pready(pready), .pslverr(pslverr),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata)
  );

  // ---- bind: timer-specific SVA onto the DUT ----
  bind apb_timer apb_timer_sva #(
    .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
  ) u_timer_sva (
    .clk(apb.clk), .rst_n(apb.rst_n), .irq(irq),
    .irq_en(ctrl_irqen), .status_irq(status_irq), .cnt(cnt),
    .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
    .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
  );

  // ---- width-consistency guard (cheap, loud, and impossible to skip) --------
  // Both sides derive from one macro today, so this can only fire if a build
  // re-introduces a second source (e.g. +define+APB_TIMER_DATA_W alone). A
  // silent mismatch would shift every RAL field against the DUT's registers.
  initial begin
    if (APB_TIMER_DATA_WIDTH != APB_DATA_WIDTH)
      `uvm_fatal("TB_WIDTH", $sformatf(
        "timer DATA_WIDTH (%0d) != APB VIP APB_DATA_WIDTH (%0d)",
        APB_TIMER_DATA_WIDTH, APB_DATA_WIDTH))
    if (APB_TIMER_ADDR_WIDTH != APB_ADDR_WIDTH)
      `uvm_fatal("TB_WIDTH", $sformatf(
        "timer ADDR_WIDTH (%0d) != APB VIP APB_ADDR_WIDTH (%0d): the DUT decodes the full paddr",
        APB_TIMER_ADDR_WIDTH, APB_ADDR_WIDTH))
  end

  // ---- config_db + run ----
  initial begin
    uvm_config_db#(virtual apb_if)::set(null, "*", "apb_vif", u_apb_if);
    uvm_config_db#(virtual timer_irq_if)::set(null, "*", "irq_vif", u_irq_if);
    run_test();
  end

  // ---- safety watchdog ----
  initial begin
    #2ms;
    `uvm_fatal("TB_WATCHDOG", "global timeout reached (2ms) - simulation hung")
  end

endmodule
