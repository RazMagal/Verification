// -----------------------------------------------------------------------------
// apb_timer_sva : timer-specific bindable assertions (plain SVA, no UVM)
//
//   Bound onto the DUT `apb_timer` so it can observe the two live interrupt
//   register bits (CTRL.IRQ_EN, STATUS.IRQ), the irq output, the live counter,
//   and the APB write strobes needed to recognise a STATUS write-1-to-clear.
//   Everything referenced exists inside apb_timer's scope, so no waveform or
//   RAL hooks are required.
//
//   Intended bind (place e.g. in the tb top / a bind file):
//
//     bind apb_timer apb_timer_sva #(
//         .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
//     ) u_timer_sva (
//         .clk(apb.clk), .rst_n(apb.rst_n), .irq(irq),
//         .irq_en(ctrl_irqen), .status_irq(status_irq), .cnt(cnt),
//         .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
//         .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
//     );
//
//   Assumptions: single clock apb.clk, active-low rst_n, checks off in reset.
// -----------------------------------------------------------------------------
module apb_timer_sva #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    input logic                  clk,
    input logic                  rst_n,
    input logic                  irq,
    input logic                  irq_en,      // CTRL.IRQ_EN (live)
    input logic                  status_irq,  // STATUS.IRQ  (live, sticky)
    input logic [DATA_WIDTH-1:0] cnt,         // live down-counter
    // APB write strobes (to detect a legal STATUS W1C)
    input logic                  psel,
    input logic                  penable,
    input logic                  pwrite,
    input logic                  pready,
    input logic [ADDR_WIDTH-1:0] paddr,
    input logic [DATA_WIDTH-1:0] pwdata
);

  localparam logic [ADDR_WIDTH-1:0] STATUS_OFF = 'h0C;

  // A completing write of 1 to STATUS.IRQ (the only legal way to clear it).
  // STATUS is always a mapped address, so this transfer never carries pslverr.
  wire w1c = psel && penable && pready && pwrite &&
             (paddr == STATUS_OFF) && pwdata[0];

  // 1) Level relationship: irq is exactly IRQ_EN & STATUS.IRQ (combinational).
  property p_irq_level;
    @(posedge clk) disable iff (!rst_n)
      irq == (irq_en & status_irq);
  endproperty
  a_irq_level : assert property (p_irq_level)
      else $error("TIMER: irq != (IRQ_EN & STATUS.IRQ)");

  // 2) irq deasserts within 1 cycle once either source is low (0 cycles for the
  //    combinational DUT; ##[0:1] tolerates a registered irq variant too).
  property p_irq_deassert;
    @(posedge clk) disable iff (!rst_n)
      (!status_irq || !irq_en) |-> ##[0:1] !irq;
  endproperty
  a_irq_deassert : assert property (p_irq_deassert)
      else $error("TIMER: irq still high after STATUS.IRQ or IRQ_EN cleared");

  // 3) STATUS.IRQ is sticky: if set and no W1C this cycle, it must stay set
  //    next cycle (HW only ever sets it; it can never self-clear).
  property p_status_sticky;
    @(posedge clk) disable iff (!rst_n)
      (status_irq && !w1c) |=> status_irq;
  endproperty
  a_status_sticky : assert property (p_status_sticky)
      else $error("TIMER: STATUS.IRQ self-cleared without a write-1-to-clear");

  // ---- Coverage -----------------------------------------------------------
  // A timeout / interrupt-assert event (STATUS.IRQ rising edge).
  c_timeout    : cover property (@(posedge clk) disable iff (!rst_n)
                    $rose(status_irq));
  // The interrupt line actually pulsing high.
  c_irq_assert : cover property (@(posedge clk) disable iff (!rst_n)
                    $rose(irq));
  // The W1C-vs-HW-set race: a W1C attempt that leaves STATUS.IRQ still set
  // (HW timeout won that cycle).
  c_w1c_race   : cover property (@(posedge clk) disable iff (!rst_n)
                    (w1c && status_irq) ##1 status_irq);

endmodule
