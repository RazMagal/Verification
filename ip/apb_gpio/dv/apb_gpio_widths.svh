// -----------------------------------------------------------------------------
// apb_gpio_widths.svh : the apb_gpio DV widths, as MACROS ONLY.
//
//   Same split as the VIP (common/apb_vip/apb_width_defines.svh + apb_params.svh):
//   macros here, `parameter int` declarations in apb_gpio_params.svh. The macro
//   half exists because ip/apb_gpio/dv/pin/gpio_if.sv compiles at $unit, BEFORE
//   apb_gpio_pkg, so it cannot see a package parameter - and its DATA_WIDTH
//   default must still be the same number as the package's, since the DV's
//   `virtual gpio_if` handles are unparameterized and take that default.
//
//   Both widths DEFAULT TO THE APB BUS WIDTHS instead of restating 8/32:
//   apb_gpio decodes its full apb.paddr as the local byte offset, and its
//   DATA_WIDTH is the width of prdata/pwdata. So in a plain build there is one
//   number, `APB_DATA_W, behind the bus, the registers and the pins, and
//   +define+APB_ADDR_W=12 moves the address width of the IP with the fabric.
//   The guards let an integration override an IP width on its own (e.g. a
//   fabric that strips the page bits and presents a narrower local offset);
//   apb_gpio_tb_top checks at time 0 that no such override left the DV's widths
//   disagreeing with the VIP's.
//
//   NOTE: there is deliberately NO pin-count macro. The pin count is not an
//   independent number - see APB_GPIO_NUM_PINS in apb_gpio_params.svh.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_WIDTHS_SVH
`define APB_GPIO_WIDTHS_SVH

`include "apb_width_defines.svh"

`ifndef APB_GPIO_ADDR_W
  `define APB_GPIO_ADDR_W `APB_ADDR_W
`endif
`ifndef APB_GPIO_DATA_W
  `define APB_GPIO_DATA_W `APB_DATA_W
`endif

`endif // APB_GPIO_WIDTHS_SVH
