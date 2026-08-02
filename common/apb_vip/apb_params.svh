// -----------------------------------------------------------------------------
// apb_params.svh : the APB VIP's compile-time widths/types, as PACKAGE items.
//   Included first in apb_vip_pkg. The widths themselves are NOT written here:
//   they come from apb_width_defines.svh, the single macro-only source shared
//   with apb_if.sv (whose parameter defaults must agree, because the VIP's
//   `virtual apb_if` handles are unparameterized) and with the per-IP params
//   files. This file only turns those macros into package parameters.
//   Standalone apb_timer/apb_gpio use ADDR=8, DATA=32. A wider build (e.g. the
//   apb_subsystem, ADDR=12) overrides the macro at compile time, which moves the
//   interface, the VIP and every IP DV package together.
// -----------------------------------------------------------------------------
`ifndef APB_PARAMS_SVH
`define APB_PARAMS_SVH

  // Guarded `define defaults (+define+APB_ADDR_W=12 overrides them). A package
  // `parameter` cannot be overridden per-instance, hence the macro indirection.
  `include "apb_width_defines.svh"

  parameter int APB_ADDR_WIDTH = `APB_ADDR_W;
  parameter int APB_DATA_WIDTH = `APB_DATA_W;

  // APB transfer direction. pwrite == APB_WRITE.
  typedef enum bit { APB_READ = 1'b0, APB_WRITE = 1'b1 } apb_dir_e;

`endif // APB_PARAMS_SVH
