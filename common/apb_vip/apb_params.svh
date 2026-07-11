// -----------------------------------------------------------------------------
// apb_params.svh : single source of truth for APB VIP compile-time widths/types
//   Included first in apb_vip_pkg. The interface (apb_if) is separately
//   parameterized; these VIP-side defaults size the seq_item / coverage model.
//   Standalone apb_timer uses ADDR=8, DATA=32. A wider build (e.g. the
//   apb_subsystem, ADDR=12) overrides these at compile time to match its apb_if.
// -----------------------------------------------------------------------------
`ifndef APB_PARAMS_SVH
`define APB_PARAMS_SVH

  // VIP transaction widths (defaults for the standalone apb_timer).
  parameter int APB_ADDR_WIDTH = 8;
  parameter int APB_DATA_WIDTH = 32;

  // APB transfer direction. pwrite == APB_WRITE.
  typedef enum bit { APB_READ = 1'b0, APB_WRITE = 1'b1 } apb_dir_e;

`endif // APB_PARAMS_SVH
