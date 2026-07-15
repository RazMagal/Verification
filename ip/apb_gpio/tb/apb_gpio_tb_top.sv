// -----------------------------------------------------------------------------
// apb_gpio_tb_top.sv : top module for the apb_gpio UVM environment.
//
//   - generates a 10ns clock and an async-assert / sync-deassert active-low reset
//   - instantiates the shared apb_if (ADDR=8,DATA=32) and the pin-side gpio_if
//   - instantiates the DUT (apb.slave modport; gpio_in driven by the gpio_if,
//     gpio_out/gpio_oe/irq wired into the gpio_if for the pin monitor)
//   - BINDS the reusable protocol checker onto apb_if and the gpio SVA onto the
//     DUT, mapping to the spec-4 internal register/synchronizer signal names
//   - sets the vifs into config_db under keys "apb_vif" / "gpio_vif" and run_test()
//
//   Compile note: apb_if.sv + gpio_if.sv compile at $unit BEFORE the packages;
//   apb_vip_pkg then apb_gpio_pkg; then RTL, SVA, this tb (see run.f). Default
//   widths (ADDR=8, DATA=32) => no APB_ADDR_W define needed.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module apb_gpio_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_vip_pkg::*;
  import apb_gpio_pkg::*;

  localparam int NPINS = 32;

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

  // ---- interfaces ----
  apb_if #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) u_apb_if ();
  gpio_if #(.DATA_WIDTH(NPINS))             u_gpio_if (.clk(clk), .rst_n(rst_n));

  assign u_apb_if.clk   = clk;
  assign u_apb_if.rst_n = rst_n;

  // ---- DUT ----
  apb_gpio #(.ADDR_WIDTH(8), .DATA_WIDTH(NPINS)) dut (
    .apb      (u_apb_if.slave),
    .gpio_in  (u_gpio_if.gpio_in),
    .gpio_out (u_gpio_if.gpio_out),
    .gpio_oe  (u_gpio_if.gpio_oe),
    .irq      (u_gpio_if.irq)
  );

  // ---- bind: reusable APB3 protocol checker onto every apb_if instance ----
  bind apb_if apb_protocol_checker #(
    .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
  ) u_apb_chk (
    .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable),
    .pwrite(pwrite), .pready(pready), .pslverr(pslverr),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata)
  );

  // ---- bind: gpio-specific SVA onto the DUT (spec-4 internal names) ----
  bind apb_gpio apb_gpio_sva #(
    .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
  ) u_gpio_sva (
    .clk(apb.clk), .rst_n(apb.rst_n),
    .gpio_out(gpio_out), .gpio_oe(gpio_oe), .irq(irq),
    .dout_q(dout_q), .dir_q(dir_q), .inten_q(inten_q),
    .intstat_q(intstat_q), .din_sync(din_sync),
    .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
    .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
  );

  // ---- config_db + run ----
  initial begin
    uvm_config_db#(virtual apb_if)::set(null, "*", "apb_vif", u_apb_if);
    uvm_config_db#(virtual gpio_if)::set(null, "*", "gpio_vif", u_gpio_if);
    run_test();
  end

  // ---- safety watchdog ----
  initial begin
    #2ms;
    `uvm_fatal("TB_WATCHDOG", "global timeout reached (2ms) - simulation hung")
  end

endmodule
