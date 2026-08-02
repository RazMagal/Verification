// -----------------------------------------------------------------------------
// apb_timer_params.svh : the apb_timer DV widths as PACKAGE parameters.
//   Included FIRST in apb_timer_pkg, so every later include (RAL, reference
//   model, scoreboard, coverage) and the tb top read their widths from here and
//   from nowhere else. Mirrors common/apb_vip/apb_params.svh: guarded `define
//   defaults (overridable with +define+..., because a package parameter cannot
//   be overridden per instance) feeding `parameter int` declarations.
//
//   Nothing on the timer side compiles at $unit needing these widths
//   (timer_irq_if carries only irq), so - unlike apb_gpio - the macros live in
//   this file instead of a separate macro-only header.
//
//   The bus widths DEFAULT TO THE APB BUS WIDTHS rather than restating 8/32:
//   apb_timer decodes its full apb.paddr as the local byte offset and its
//   registers are prdata-wide. That is also what the SoC does - soc/apb_subsystem
//   builds with +define+APB_ADDR_W=12 and instantiates apb_timer with
//   ADDR_WIDTH=12, so the DV's notion of the address width follows the fabric
//   automatically, with no second place to edit.
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_PARAMS_SVH
`define APB_TIMER_PARAMS_SVH

  `include "apb_width_defines.svh"

`ifndef APB_TIMER_ADDR_W
  `define APB_TIMER_ADDR_W `APB_ADDR_W
`endif
`ifndef APB_TIMER_DATA_W
  `define APB_TIMER_DATA_W `APB_DATA_W
`endif
  // PRESCALE.[7:0] (spec 2.5). This one is genuinely the IP's own width - it is
  // NOT derived from the bus - so it gets its own guarded knob.
`ifndef APB_TIMER_PRESC_W
  `define APB_TIMER_PRESC_W 8
`endif

  parameter int APB_TIMER_ADDR_WIDTH     = `APB_TIMER_ADDR_W;
  parameter int APB_TIMER_DATA_WIDTH     = `APB_TIMER_DATA_W;
  parameter int APB_TIMER_PRESCALE_WIDTH = `APB_TIMER_PRESC_W;

  // ---- Register field geometry (spec 2), all DERIVED from the widths above ---
  // CTRL   : EN[0], MODE[1], IRQ_EN[2], reserved[DATA-1:3]
  // STATUS : IRQ[0],                    reserved[DATA-1:1]
  // The reserved fields are the ones that break SILENTLY when the data width
  // moves (a stale 29/31 either overlaps a real field or leaves a hole in the
  // register), so they are stated as "the rest of the register", never as a
  // number: RSVD_WIDTH = DATA_WIDTH - <lsb>, and <lsb> = the flag count.
  parameter int APB_TIMER_CTRL_FLAGS         = 3;   // EN, MODE, IRQ_EN
  parameter int APB_TIMER_STATUS_FLAGS       = 1;   // IRQ
  parameter int APB_TIMER_CTRL_RSVD_LSB      = APB_TIMER_CTRL_FLAGS;
  parameter int APB_TIMER_CTRL_RSVD_WIDTH    = APB_TIMER_DATA_WIDTH -
                                               APB_TIMER_CTRL_RSVD_LSB;
  parameter int APB_TIMER_STATUS_RSVD_LSB    = APB_TIMER_STATUS_FLAGS;
  parameter int APB_TIMER_STATUS_RSVD_WIDTH  = APB_TIMER_DATA_WIDTH -
                                               APB_TIMER_STATUS_RSVD_LSB;
  parameter int APB_TIMER_PRESC_RSVD_LSB     = APB_TIMER_PRESCALE_WIDTH;
  parameter int APB_TIMER_PRESC_RSVD_WIDTH   = APB_TIMER_DATA_WIDTH -
                                               APB_TIMER_PRESCALE_WIDTH;

  // Largest programmable prescale divider-1 (all ones of the prescale field).
  parameter bit [APB_TIMER_PRESCALE_WIDTH-1:0] APB_TIMER_PRESCALE_MAX = '1;

  // Reset value shared by every apb_timer register (spec 2: all reset to 0).
  parameter uvm_reg_data_t APB_TIMER_REG_RESET = '0;

`endif // APB_TIMER_PARAMS_SVH
