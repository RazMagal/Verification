// -----------------------------------------------------------------------------
// gpio_if : pin-side interface for the apb_gpio IP (analogous to timer_irq_if,
//   but bidirectional-style: the DV drives gpio_in and observes gpio_out /
//   gpio_oe / irq).
//
//   - gpio_in  is DRIVEN by the pin driver (through drv_cb) into the DUT input.
//   - gpio_out / gpio_oe / irq are DUT outputs, wired in by the tb top and
//     SAMPLED race-free by the pin monitor (through mon_cb).
//   - Same clk / active-low rst_n as the APB side.
//
//   DATA_WIDTH defaults to 32 (== NPINS). A `virtual gpio_if` handle is
//   unparameterized and takes this default, so every gpio_if instance in one
//   build must share the width (the standalone build uses the default 32).
// -----------------------------------------------------------------------------
interface gpio_if #(parameter int DATA_WIDTH = 32)
                   (input logic clk, input logic rst_n);

  logic [DATA_WIDTH-1:0] gpio_in;   // DV-driven external pin inputs
  logic [DATA_WIDTH-1:0] gpio_out;  // DUT output (observed)
  logic [DATA_WIDTH-1:0] gpio_oe;   // DUT output enable (observed)
  logic                  irq;       // DUT level interrupt (observed)

  // Active driving of the external inputs (output skew 0 -> the DUT input flop
  // sees the previous value at the next posedge, a clean one-cycle relationship).
  clocking drv_cb @(posedge clk);
    output gpio_in;
  endclocking

  // Passive sampling of the pins + outputs, preponed (race-free).
  clocking mon_cb @(posedge clk);
    input gpio_in, gpio_out, gpio_oe, irq;
  endclocking

  modport drv_mp (clocking drv_cb, input rst_n);
  modport mon_mp (clocking mon_cb, input rst_n,
                  input gpio_in, gpio_out, gpio_oe, irq);

endinterface
