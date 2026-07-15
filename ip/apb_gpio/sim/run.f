// ---------------------------------------------------------------------------
// run.f : compile-order filelist for the apb_gpio UVM env.
//   Paths are RELATIVE TO THE REPO ROOT (the dir holding common/ and ip/). The
//   Makefile cd's to the repo root before invoking the simulator with -f/-F.
//   Order: incdirs -> interfaces ($unit) -> packages -> RTL -> SVA -> tb.
//   Default widths (ADDR=8, DATA=32) => NO +define needed.
// ---------------------------------------------------------------------------

// include directories (for the `include of the .svh sources inside packages)
+incdir+common/apb_vip
+incdir+ip/apb_gpio/dv
+incdir+ip/apb_gpio/dv/pin
+incdir+ip/apb_gpio/dv/seq
+incdir+ip/apb_gpio/dv/test

// 1) interfaces  (compile at $unit, BEFORE the packages that use their types)
common/apb_vip/apb_if.sv
ip/apb_gpio/dv/pin/gpio_if.sv

// 2) packages  (VIP first, then the gpio DV package)
common/apb_vip/apb_vip_pkg.sv
ip/apb_gpio/dv/apb_gpio_pkg.sv

// 3) RTL
ip/apb_gpio/rtl/apb_gpio.sv

// 4) bindable SVA (plain SVA modules, bound in the tb top)
common/apb_vip/apb_protocol_checker.sv
ip/apb_gpio/rtl/apb_gpio_sva.sv

// 5) testbench top
ip/apb_gpio/tb/apb_gpio_tb_top.sv
