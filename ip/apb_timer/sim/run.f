// ---------------------------------------------------------------------------
// run.f : compile-order filelist for the apb_timer UVM env.
//   Paths are RELATIVE TO THE REPO ROOT (the dir holding common/ and ip/). The
//   Makefile cd's to the repo root before invoking the simulator with -f/-F.
//   Order: incdirs -> interfaces ($unit) -> packages -> RTL -> SVA -> tb.
// ---------------------------------------------------------------------------

// include directories (for the `include of the .svh sources inside packages)
+incdir+common/apb_vip
+incdir+ip/apb_timer/dv
+incdir+ip/apb_timer/dv/irq
+incdir+ip/apb_timer/dv/seq
+incdir+ip/apb_timer/dv/test

// 1) interfaces  (compile at $unit, BEFORE the packages that use their types)
common/apb_vip/apb_if.sv
ip/apb_timer/dv/irq/timer_irq_if.sv

// 2) packages  (VIP first, then the timer DV package)
common/apb_vip/apb_vip_pkg.sv
ip/apb_timer/dv/apb_timer_pkg.sv

// 3) RTL
ip/apb_timer/rtl/apb_timer.sv

// 4) bindable SVA (plain SVA modules, bound in the tb top)
common/apb_vip/apb_protocol_checker.sv
ip/apb_timer/rtl/apb_timer_sva.sv

// 5) testbench top
ip/apb_timer/tb/apb_timer_tb_top.sv
