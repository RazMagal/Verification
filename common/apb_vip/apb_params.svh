// -----------------------------------------------------------------------------
// apb_params.svh : single source of truth for APB VIP compile-time widths/types
//   Included first in apb_vip_pkg. The interface (apb_if) is separately
//   parameterized; these VIP-side defaults size the seq_item / coverage model.
//   Standalone apb_timer uses ADDR=8, DATA=32. A wider build (e.g. the
//   apb_subsystem, ADDR=12) overrides these at compile time to match its apb_if.
// -----------------------------------------------------------------------------
`ifndef APB_PARAMS_SVH
`define APB_PARAMS_SVH

  // VIP transaction widths. Default to the standalone apb_timer (ADDR=8,DATA=32).
  // A wider build overrides them at COMPILE TIME with a plusarg define, e.g. the
  // apb_subsystem drives a 12-bit address bus:  +define+APB_ADDR_W=12
  // (a package `parameter` cannot be overridden per-instance, so the width comes
  // in through these guarded macros before the package parameters are elaborated).
`ifndef APB_ADDR_W
  `define APB_ADDR_W 8
`endif
`ifndef APB_DATA_W
  `define APB_DATA_W 32
`endif

  parameter int APB_ADDR_WIDTH = `APB_ADDR_W;
  parameter int APB_DATA_WIDTH = `APB_DATA_W;

  // APB transfer direction. pwrite == APB_WRITE.
  typedef enum bit { APB_READ = 1'b0, APB_WRITE = 1'b1 } apb_dir_e;

`endif // APB_PARAMS_SVH
