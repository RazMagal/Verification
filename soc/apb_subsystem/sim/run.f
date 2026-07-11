// ---------------------------------------------------------------------------
// run.f : compile-order filelist for the apb_subsystem UVM env.
//   Paths are RELATIVE TO THE REPO ROOT (the dir holding common/, ip/, soc/).
//   The Makefile cd's to the repo root before invoking the simulator with -f.
//   Order: define -> incdirs -> interfaces ($unit) -> packages -> RTL -> SVA -> tb.
//
//   REUSE: this env pulls in the shared APB VIP (common/apb_vip) and the entire
//   apb_timer IP DV (ip/apb_timer/dv) unmodified; only soc/apb_subsystem/dv adds
//   the thin subsystem composition.
// ---------------------------------------------------------------------------

// 0) width define : MUST be first -> every apb_if instance + the VIP virtual
//    interface handles become 12-bit for the whole build.
+define+APB_ADDR_W=12

// 1) include directories (for `include of the .svh sources inside packages)
+incdir+common/apb_vip
+incdir+ip/apb_timer/dv
+incdir+ip/apb_timer/dv/irq
+incdir+ip/apb_timer/dv/seq
+incdir+ip/apb_timer/dv/test
+incdir+soc/apb_subsystem/dv
+incdir+soc/apb_subsystem/dv/seq
+incdir+soc/apb_subsystem/dv/test

// 2) interfaces (compile at $unit, BEFORE the packages that use their types)
common/apb_vip/apb_if.sv
ip/apb_timer/dv/irq/timer_irq_if.sv

// 3) packages (VIP -> timer DV -> subsystem DV)
common/apb_vip/apb_vip_pkg.sv
ip/apb_timer/dv/apb_timer_pkg.sv
soc/apb_subsystem/dv/apb_subsystem_pkg.sv

// 4) RTL (leaves before the integration top)
ip/apb_timer/rtl/apb_timer.sv
soc/apb_subsystem/rtl/apb_mem_slave.sv
soc/apb_subsystem/rtl/apb_interconnect.sv
soc/apb_subsystem/rtl/apb_subsystem.sv

// 5) bindable SVA (plain SVA modules, bound in the tb top)
common/apb_vip/apb_protocol_checker.sv
ip/apb_timer/rtl/apb_timer_sva.sv

// 6) testbench top
soc/apb_subsystem/tb/apb_subsystem_tb_top.sv
