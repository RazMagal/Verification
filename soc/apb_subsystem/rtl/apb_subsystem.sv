// -----------------------------------------------------------------------------
// apb_subsystem : APB3 subsystem top - two apb_timer instances + a memory slave
//
//   Block diagram:
//
//                        +-----------------------+
//     apb (12-bit,       |    apb_interconnect    |
//     slave modport) --->| up   decode paddr[11:8]|
//                        |            /  |  \      |
//                        +----------d0--d1--d2-----+
//                                   |    |    |
//                        t0_if(8) --+    |    +-- mem_if(8)
//                                        |
//                                   t1_if(8)
//                                   |    |          |
//                            +------v-+ +v------+ +-v----------+
//                            |apb_timer| |apb_timer| |apb_mem_slave|
//                            | u_timer0| | u_timer1| |   u_mem     |
//                            +----|----+ +----|----+ +------------+
//                                 irq0        irq1
//
//   Address map (subsystem APB: ADDR_WIDTH=12, DATA_WIDTH=32; decode paddr[11:8]):
//     0x000..0x0FF -> timer0 (u_timer0, irq0)
//     0x100..0x1FF -> timer1 (u_timer1, irq1)
//     0x200..0x2FF -> mem    (u_mem)
//     else         -> pslverr (unmapped, fabric-generated)
//
//   Clocking / reset: single clock apb.clk; active-low apb.rst_n (async assert /
//   sync deassert) - both fanned out from the upstream interface to every
//   downstream interface instance below.
//
//   Interface-instance port connections: downstream interfaces are passed as
//   BARE instances (e.g. .d0(t0_if), .apb(t0_if)); each port's own declared
//   modport (apb_if.master on the interconnect, apb_if.slave on the DUTs)
//   selects the driven/observed direction set. This is the portable SV-2017
//   form and avoids over-constraining a single instance to one modport view.
// -----------------------------------------------------------------------------
`default_nettype none

module apb_subsystem (
    apb_if.slave apb,           // upstream APB3 : ADDR_WIDTH=12, DATA_WIDTH=32
    output logic irq0,          // timer0 interrupt
    output logic irq1           // timer1 interrupt
);

  // ---- Downstream interface instances --------------------------------------
  // All apb_if instances share ADDR_WIDTH=12 so the reusable APB VIP (whose
  // virtual-interface handles take the default width) can bind a passive
  // monitor to any of them in the subsystem env. The interconnect still hands
  // each peripheral only the base-stripped low byte, so the timers/mem decode
  // their local offsets in the low bits (upper bits are zero).
  apb_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) t0_if ();
  apb_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) t1_if ();
  apb_if #(.ADDR_WIDTH(12), .DATA_WIDTH(32)) mem_if ();

  // ---- Fan out clock / reset from the upstream to each downstream ----------
  assign t0_if.clk    = apb.clk;
  assign t0_if.rst_n  = apb.rst_n;
  assign t1_if.clk    = apb.clk;
  assign t1_if.rst_n  = apb.rst_n;
  assign mem_if.clk   = apb.clk;
  assign mem_if.rst_n = apb.rst_n;

  // ---- APB fabric : 1 upstream -> 3 downstream -----------------------------
  apb_interconnect #(
      .ADDR_WIDTH(12),
      .DATA_WIDTH(32)
  ) u_xbar (
      .up (apb),
      .d0 (t0_if),
      .d1 (t1_if),
      .d2 (mem_if)
  );

  // ---- Peripherals ---------------------------------------------------------
  apb_timer #(
      .ADDR_WIDTH(12),
      .DATA_WIDTH(32)
  ) u_timer0 (
      .apb (t0_if),
      .irq (irq0)
  );

  apb_timer #(
      .ADDR_WIDTH(12),
      .DATA_WIDTH(32)
  ) u_timer1 (
      .apb (t1_if),
      .irq (irq1)
  );

  apb_mem_slave #(
      .ADDR_WIDTH(12),
      .DATA_WIDTH(32)
  ) u_mem (
      .apb (mem_if)
  );

endmodule

`default_nettype wire
