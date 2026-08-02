// ---------------------------------------------------------------------------
// run.f : compile-order filelist for the photonic_ring_tuner UVM env.
//   Paths are RELATIVE TO THE REPO ROOT (the dir holding common/ and ip/). The
//   Makefile cd's to the repo root before invoking the simulator with -f/-F.
//   Order: incdirs -> interfaces ($unit) -> DPI ABI package -> packages ->
//          optical model -> RTL -> SVA -> tb.
//   Default APB widths (ADDR=8, DATA=32) => NO +define needed.
// ---------------------------------------------------------------------------

// include directories (for the `include of the .svh sources inside packages)
+incdir+common/apb_vip
+incdir+ip/photonic_ring_tuner/dv
+incdir+ip/photonic_ring_tuner/dv/optics
+incdir+ip/photonic_ring_tuner/dv/seq
+incdir+ip/photonic_ring_tuner/dv/test

// 1) interfaces  (compile at $unit, BEFORE the packages that use their types)
common/apb_vip/apb_if.sv
ip/photonic_ring_tuner/dv/optics/ring_if.sv

// 2) the DPI-C ABI package  (BEFORE the packages that import it:
//    photonic_ring_tuner_pkg and, at step 3, ring_model.sv)
//
//    A filelist cannot carry an `ifdef, so this line is UNCONDITIONAL and the
//    guard lives inside the file instead: without +define+RING_DPI,
//    photonics_dpi_pkg compiles to an EMPTY package -- no functions, and NO
//    import "DPI-C" / export "DPI-C" at all. Nothing imports it in that build,
//    there is no C symbol to resolve and no shared library to link, so the
//    default flow is behaviourally untouched -- which matters because these UVM
//    runs happen on EDA Playground, where user C cannot be compiled.
//    Add +define+RING_DPI (see the *_dpi targets in sim/Makefile) to switch the
//    layer on.
common/dpi/photonics_dpi_pkg.sv

// 3) packages  (VIP first, then the tuner DV package)
common/apb_vip/apb_vip_pkg.sv
ip/photonic_ring_tuner/dv/photonic_ring_tuner_pkg.sv

// 4) optical model (DV, NON-SYNTHESIZABLE - closes the loop in the tb)
ip/photonic_ring_tuner/dv/optics/ring_model.sv

// 5) RTL
ip/photonic_ring_tuner/rtl/photonic_ring_tuner.sv

// 6) bindable SVA (plain SVA modules, bound in the tb top)
common/apb_vip/apb_protocol_checker.sv
ip/photonic_ring_tuner/rtl/photonic_ring_tuner_sva.sv

// 7) testbench top
ip/photonic_ring_tuner/tb/photonic_ring_tuner_tb_top.sv
