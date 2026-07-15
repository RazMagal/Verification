// -----------------------------------------------------------------------------
// apb_gpio_sva : gpio-specific bindable assertions (plain SVA, no UVM)
//
//   Bound onto the DUT `apb_gpio` so it can observe the output mirrors
//   (gpio_out/gpio_oe), the interrupt output, the four architectural registers
//   plus the synchronized input (din_sync), and the APB write strobes needed to
//   recognise a legal INT_STATUS write-1-to-clear. Everything referenced exists
//   inside apb_gpio's scope, so no waveform or RAL hooks are required.
//
//   Intended bind (place e.g. in the tb top / a bind file):
//
//     bind apb_gpio apb_gpio_sva #(
//         .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
//     ) u_gpio_sva (
//         .clk(apb.clk), .rst_n(apb.rst_n), .irq(irq),
//         .gpio_out(gpio_out), .gpio_oe(gpio_oe),
//         .dout_q(dout_q), .dir_q(dir_q), .inten_q(inten_q),
//         .intstat_q(intstat_q), .din_sync(din_sync),
//         .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
//         .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
//     );
//
//   Assumptions: single clock apb.clk, active-low rst_n, checks off in reset.
// -----------------------------------------------------------------------------
module apb_gpio_sva #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    input logic                  clk,
    input logic                  rst_n,
    input logic                  irq,
    // Output mirrors + architectural state (live)
    input logic [DATA_WIDTH-1:0] gpio_out,
    input logic [DATA_WIDTH-1:0] gpio_oe,
    input logic [DATA_WIDTH-1:0] dout_q,     // DATA_OUT
    input logic [DATA_WIDTH-1:0] dir_q,      // DIR
    input logic [DATA_WIDTH-1:0] inten_q,    // INT_EN
    input logic [DATA_WIDTH-1:0] intstat_q,  // INT_STATUS (sticky)
    input logic [DATA_WIDTH-1:0] din_sync,   // synchronized input (DATA_IN)
    // APB write strobes (to detect a legal INT_STATUS W1C)
    input logic                  psel,
    input logic                  penable,
    input logic                  pwrite,
    input logic                  pready,
    input logic [ADDR_WIDTH-1:0] paddr,
    input logic [DATA_WIDTH-1:0] pwdata
);

  localparam logic [ADDR_WIDTH-1:0] INT_STATUS_OFF = 'h0C;

  // A completing write to INT_STATUS (the only legal way to clear its bits).
  // INT_STATUS is always a mapped address, so this transfer never carries
  // pslverr; pwdata[i]==1 is the per-bit write-1-to-clear request.
  wire w1c_xfer = psel && penable && pready && pwrite && (paddr == INT_STATUS_OFF);

  // 1) Output enable follows DIR (spec §3.1 / §5.1).
  property p_oe_follows_dir;
    @(posedge clk) disable iff (!rst_n)
      gpio_oe == dir_q;
  endproperty
  a_oe_follows_dir : assert property (p_oe_follows_dir)
      else $error("GPIO: gpio_oe != dir_q");

  // 2) Output value follows DATA_OUT (spec §3.1 / §5.2).
  property p_out_follows_dout;
    @(posedge clk) disable iff (!rst_n)
      gpio_out == dout_q;
  endproperty
  a_out_follows_dout : assert property (p_out_follows_dout)
      else $error("GPIO: gpio_out != dout_q");

  // 3) Interrupt level = OR of enabled, set status bits (spec §3.3 / §5.3).
  property p_irq_level;
    @(posedge clk) disable iff (!rst_n)
      irq == (|(intstat_q & inten_q));
  endproperty
  a_irq_level : assert property (p_irq_level)
      else $error("GPIO: irq != |(INT_STATUS & INT_EN)");

  // 4) INT_STATUS is per-pin sticky (spec §3.3 / §5.4): a set bit that is not
  //    write-1-cleared this cycle must remain set next cycle (HW only ever sets
  //    it; it can never self-clear).  Per-bit via genvar.
  for (genvar i = 0; i < DATA_WIDTH; i++) begin : g_intstat
    property p_intstat_sticky;
      @(posedge clk) disable iff (!rst_n)
        (intstat_q[i] && !(w1c_xfer && pwdata[i])) |=> intstat_q[i];
    endproperty
    a_intstat_sticky : assert property (p_intstat_sticky)
        else $error("GPIO: INT_STATUS[%0d] self-cleared without a W1C", i);

    // The W1C-vs-HW-set race (spec §3.3 / §5 cover): a W1C attempt on bit i
    // while it is set, that leaves the bit still set next cycle (HW edge won).
    c_w1c_race : cover property (@(posedge clk) disable iff (!rst_n)
        (w1c_xfer && pwdata[i] && intstat_q[i]) ##1 intstat_q[i]);
  end

  // ---- Coverage -----------------------------------------------------------
  // Any INT_STATUS bit rising (a detected pin edge became visible).
  c_intstat_rise : cover property (@(posedge clk) disable iff (!rst_n)
                      $rose(|intstat_q));
  // The interrupt line actually pulsing high.
  c_irq_assert   : cover property (@(posedge clk) disable iff (!rst_n)
                      $rose(irq));

endmodule
