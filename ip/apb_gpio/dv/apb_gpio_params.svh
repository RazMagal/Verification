// -----------------------------------------------------------------------------
// apb_gpio_params.svh : the apb_gpio DV widths as PACKAGE parameters.
//   Included FIRST in apb_gpio_pkg, so every later include (RAL, pin agent,
//   reference model, coverage) and the tb top read their widths from here and
//   from nowhere else. Mirrors common/apb_vip/apb_params.svh: guarded `define
//   defaults (apb_gpio_widths.svh, overridable with +define+...) feeding
//   `parameter int` declarations, because a package parameter cannot be
//   overridden per instance.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_PARAMS_SVH
`define APB_GPIO_PARAMS_SVH

  `include "apb_gpio_widths.svh"

  // Local register-offset decode width and register/data width. Both default to
  // the APB bus widths (see apb_gpio_widths.svh) - apb_gpio decodes its full
  // apb.paddr and its registers are prdata-wide.
  parameter int APB_GPIO_ADDR_WIDTH = `APB_GPIO_ADDR_W;
  parameter int APB_GPIO_DATA_WIDTH = `APB_GPIO_DATA_W;

  // ---- The pin count IS the data width. Not "equal to" - the SAME number. ----
  // rtl/apb_gpio.sv:  parameter int DATA_WIDTH = 32   // also NPINS
  // Every register (DATA_OUT/DATA_IN/DIR/INT_STATUS/INT_EN) is one bit per pin,
  // so bit i of every register and pin i are the same index by construction.
  // This is an ALIAS, not a second knob: there is no `APB_GPIO_NPINS macro that
  // could be defined to something else and silently desynchronize the RAL field
  // widths from the pin vectors. Change the pin count by changing the data
  // width (`APB_DATA_W / `APB_GPIO_DATA_W) - which also moves apb_if, gpio_if,
  // the DUT parameter and the RAL together.
  parameter int APB_GPIO_NUM_PINS = APB_GPIO_DATA_WIDTH;

  // Width-dependent pin-vector extremes (all pins low / all pins high). Used by
  // the coverage bins so "all outputs" cannot silently mean "32 outputs" once
  // the pin count changes.
  parameter bit [APB_GPIO_NUM_PINS-1:0] APB_GPIO_PINS_NONE = '0;
  parameter bit [APB_GPIO_NUM_PINS-1:0] APB_GPIO_PINS_ALL  = '1;

  // Reset value shared by every apb_gpio register (spec 2: all reset to 0).
  parameter uvm_reg_data_t APB_GPIO_REG_RESET = '0;

`endif // APB_GPIO_PARAMS_SVH
