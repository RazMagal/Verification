// -----------------------------------------------------------------------------
// apb_gpio_tb_top.sv : top module for the apb_gpio UVM environment.
//
//   - generates a 10ns clock and an async-assert / sync-deassert active-low reset
//   - instantiates the shared apb_if and the pin-side gpio_if, BOTH at their
//     default widths (`APB_ADDR_W / `APB_GPIO_DATA_W) - the tb states no width
//     of its own, so the interfaces, the DUT, the RAL and the VIP cannot drift
//   - instantiates the DUT (apb.slave modport; gpio_in driven by the gpio_if,
//     gpio_out/gpio_oe/irq wired into the gpio_if for the pin monitor)
//   - BINDS the reusable protocol checker onto apb_if and the gpio SVA onto the
//     DUT, mapping to the spec-4 internal register/synchronizer signal names
//   - sets the vifs into config_db under keys "apb_vif" / "gpio_vif" and run_test()
//
//   Compile note: apb_if.sv + gpio_if.sv compile at $unit BEFORE the packages;
//   apb_vip_pkg then apb_gpio_pkg; then RTL, SVA, this tb (see run.f). Default
//   widths (ADDR=8, DATA=32 = NPINS) => no APB_ADDR_W define needed. Both
//   interfaces are instantiated WITHOUT parameter overrides on purpose: the VIP's
//   `virtual apb_if` / `virtual gpio_if` handles are unparameterized, so only the
//   defaults are usable, and those defaults come from the same macros the DV
//   packages elaborate from (apb_width_defines.svh -> apb_gpio_widths.svh).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module apb_gpio_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_vip_pkg::*;
  import apb_gpio_pkg::*;

  // NOTE: no local width parameters here. The pin count, the register width and
  // the address width all arrive from apb_gpio_pkg (APB_GPIO_NUM_PINS ===
  // APB_GPIO_DATA_WIDTH by construction, see apb_gpio_params.svh).

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
  apb_if  u_apb_if  ();
  gpio_if u_gpio_if (.clk(clk), .rst_n(rst_n));

  assign u_apb_if.clk   = clk;
  assign u_apb_if.rst_n = rst_n;

  // ---- DUT ----
  // DATA_WIDTH is passed the PIN COUNT, because for this IP they are the same
  // number (rtl: `parameter int DATA_WIDTH = 32   // also NPINS`).
  apb_gpio #(
    .ADDR_WIDTH (APB_GPIO_ADDR_WIDTH),
    .DATA_WIDTH (APB_GPIO_NUM_PINS)
  ) dut (
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

  // ---- width-consistency guard (cheap, loud, and impossible to skip) --------
  // Everything below derives from one macro today, so this can only fire if a
  // build re-introduces a second source (e.g. +define+APB_GPIO_DATA_W without
  // the matching +define+APB_DATA_W). It is checked at time 0, before stimulus,
  // because a silent mismatch here shifts every RAL field against the DUT.
  initial begin
    if (APB_GPIO_NUM_PINS != APB_GPIO_DATA_WIDTH)
      `uvm_fatal("TB_WIDTH", $sformatf(
        "pin count (%0d) != gpio DATA_WIDTH (%0d): they are the same number by construction",
        APB_GPIO_NUM_PINS, APB_GPIO_DATA_WIDTH))
    if (APB_GPIO_DATA_WIDTH != APB_DATA_WIDTH)
      `uvm_fatal("TB_WIDTH", $sformatf(
        "gpio DATA_WIDTH (%0d) != APB VIP APB_DATA_WIDTH (%0d): the pins ride the APB data bus",
        APB_GPIO_DATA_WIDTH, APB_DATA_WIDTH))
    if (APB_GPIO_ADDR_WIDTH != APB_ADDR_WIDTH)
      `uvm_fatal("TB_WIDTH", $sformatf(
        "gpio ADDR_WIDTH (%0d) != APB VIP APB_ADDR_WIDTH (%0d): the DUT decodes the full paddr",
        APB_GPIO_ADDR_WIDTH, APB_ADDR_WIDTH))
  end

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
