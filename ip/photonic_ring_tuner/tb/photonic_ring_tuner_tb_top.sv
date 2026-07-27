// -----------------------------------------------------------------------------
// photonic_ring_tuner_tb_top.sv : top module for the photonic_ring_tuner UVM env.
//
//   - generates a 10ns clock and an async-assert / sync-deassert active-low reset
//   - instantiates the shared apb_if (ADDR=8, DATA=32) and the optical ring_if
//   - instantiates the DUT and CLOSES THE LOOP through ring_model:
//         dut.dac_code -> ring_if -> ring_model -> ring_if.adc_code -> dut
//     There is no stimulus generator on the optical side; the ring's physical
//     parameters are randomized per test (ring_cfg) and the loop then drives
//     itself.
//   - BINDS the reusable APB protocol checker onto apb_if and the tuner SVA onto
//     the DUT, mapping to the spec-4 internal signal names
//   - sets the vifs into config_db under keys "apb_vif" / "ring_vif" and run_test()
//
//   Compile note: apb_if.sv + ring_if.sv compile at $unit BEFORE the packages;
//   apb_vip_pkg then photonic_ring_tuner_pkg; then ring_model, RTL, SVA, this tb
//   (see run.f). Default APB widths (ADDR=8, DATA=32) => no APB_ADDR_W define.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module photonic_ring_tuner_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import apb_vip_pkg::*;
  import photonic_ring_tuner_pkg::*;

  // CamelCase localparams: Verible's constant naming rule reserves ALL_CAPS with
  // underscores for module PARAMETERS (which these feed by name below).
  localparam int AddrWidth = 8;
  localparam int DataWidth = 32;
  localparam int DacWidth  = 12;
  localparam int AdcWidth  = 12;
  localparam int LockN     = 4;

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
  apb_if #(.ADDR_WIDTH(AddrWidth), .DATA_WIDTH(DataWidth)) u_apb_if ();
  ring_if #(.DAC_WIDTH(DacWidth), .ADC_WIDTH(AdcWidth))    u_ring_if (
    .clk(clk), .rst_n(rst_n));

  assign u_apb_if.clk   = clk;
  assign u_apb_if.rst_n = rst_n;

  // ---- DUT ----
  photonic_ring_tuner #(
    .ADDR_WIDTH(AddrWidth),
    .DATA_WIDTH(DataWidth),
    .DAC_WIDTH (DacWidth),
    .ADC_WIDTH (AdcWidth),
    .LOCK_N    (LockN)
  ) dut (
    .apb      (u_apb_if.slave),
    .adc_code (u_ring_if.adc_code),
    .dac_code (u_ring_if.dac_code),
    .locked   (u_ring_if.locked)
  );

  // ---- the optical model : this instance is what CLOSES the control loop ----
  ring_model #(
    .DAC_WIDTH(DacWidth),
    .ADC_WIDTH(AdcWidth)
  ) u_ring_model (
    .ring (u_ring_if.model_mp)
  );

  // ---- bind: reusable APB3 protocol checker onto every apb_if instance ----
  bind apb_if apb_protocol_checker #(
    .ADDR_WIDTH(AddrWidth), .DATA_WIDTH(DataWidth)
  ) u_apb_chk (
    .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable),
    .pwrite(pwrite), .pready(pready), .pslverr(pslverr),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata)
  );

  // ---- bind: tuner-specific SVA onto the DUT (spec-4 internal names) ----
  bind photonic_ring_tuner photonic_ring_tuner_sva #(
    .ADDR_WIDTH(AddrWidth), .DATA_WIDTH(DataWidth), .DAC_WIDTH(DacWidth),
    .ADC_WIDTH(AdcWidth), .LOCK_N(LockN)
  ) u_tuner_sva (
    .clk(apb.clk), .rst_n(apb.rst_n),
    .state_q(state_q),
    .dac_q(dac_q), .dac_code(dac_code), .best_code_q(best_code_q),
    .p_hi_q(p_hi_q), .p_lo_q(p_lo_q), .pd_q(pd_q), .best_adc_q(best_adc_q),
    .adc_code(adc_code),
    .locked(locked), .locked_q(locked_q), .rail_err_q(rail_err_q),
    .sweep_err_q(sweep_err_q), .en_q(en_q),
    .thresh_q(thresh_q), .minpow_q(minpow_q), .settle_q(settle_q),
    .dither_q(dither_q), .sweep_q(sweep_q),
    .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
    .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
  );

  // ---- config_db + run ----
  initial begin
    uvm_config_db#(virtual apb_if)::set(null, "*", "apb_vif", u_apb_if);
    uvm_config_db#(virtual ring_if)::set(null, "*", "ring_vif", u_ring_if);
    run_test();
  end

  // ---- safety watchdog ----
  // Sized for the worst legal acquisition this env can ask for: a full
  // 4096-point coarse sweep (SWEEP = 1) at the default SETTLE of 32 is about
  // 1.4 ms at 100 MHz. 5 ms leaves room for that plus a fine lock and the drain,
  // and still fails fast instead of hanging a regression.
  initial begin
    #5ms;
    `uvm_fatal("TB_WATCHDOG", "global timeout reached (5ms) - simulation hung")
  end

endmodule
