// -----------------------------------------------------------------------------
// apb_width_defines.svh : the ONE place the APB bus widths are written down.
//
//   MACROS ONLY - no declarations - so this file is safe to `include anywhere:
//     * at $unit, by files that cannot see a package parameter because they are
//       compiled before every package (apb_if.sv, ip/apb_gpio/dv/pin/gpio_if.sv);
//     * inside a package, by apb_params.svh and the per-IP *_params.svh, which
//       turn these macros into `parameter int` declarations.
//
//   That split IS the mechanism: a SystemVerilog package parameter cannot be
//   overridden per instance, so the width has to arrive as a compile-time macro
//   BEFORE the package parameters elaborate:
//       +define+APB_ADDR_W=12        <- the apb_subsystem build does exactly this
//   Every definition below is `ifndef-guarded, so a command-line +define always
//   wins and the numbers here are only the fallback for a plain standalone build.
//
//   Included (directly or transitively) by:
//     common/apb_vip/apb_params.svh          -> apb_vip_pkg parameters
//     common/apb_vip/apb_if.sv               -> interface parameter DEFAULTS
//     ip/apb_gpio/dv/apb_gpio_widths.svh     -> gpio_if default + gpio DV params
//     ip/apb_timer/dv/apb_timer_params.svh   -> timer DV params
//   Keeping the interface defaults and the VIP/IP parameters on the same macro is
//   load-bearing: the VIP's `virtual apb_if` handles are UNPARAMETERIZED, so they
//   take the interface defaults, and every apb_if instance in one build must
//   therefore share exactly this width.
// -----------------------------------------------------------------------------
`ifndef APB_WIDTH_DEFINES_SVH
`define APB_WIDTH_DEFINES_SVH

`ifndef APB_ADDR_W
  `define APB_ADDR_W 8
`endif
`ifndef APB_DATA_W
  `define APB_DATA_W 32
`endif

`endif // APB_WIDTH_DEFINES_SVH
