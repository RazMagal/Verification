// -----------------------------------------------------------------------------
// timer_irq_if : passive observation interface for the apb_timer irq line.
//   The DUT's `irq` output is wired into this interface's `irq` variable by the
//   tb top. A clocking block samples it race-free for the passive monitor.
// -----------------------------------------------------------------------------
interface timer_irq_if (input logic clk, input logic rst_n);

  logic irq;

  // Passive monitor sampling of the level-sensitive interrupt.
  clocking mon_cb @(posedge clk);
    input irq;
  endclocking

  modport mon_mp (clocking mon_cb, input rst_n, input irq);

endinterface
