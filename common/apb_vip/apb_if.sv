// -----------------------------------------------------------------------------
// apb_if : AMBA APB3 interface (shared VIP)
//   Parameterized address/data widths so the same interface serves both the
//   standalone apb_timer (ADDR_WIDTH=8) and the apb_subsystem (ADDR_WIDTH=12).
//   Clocking blocks + modports give the UVM driver/monitor race-free access.
//
//   The DEFAULT widths track the same `APB_ADDR_W / `APB_DATA_W macros the VIP
//   uses (see apb_params.svh). This matters because a `virtual apb_if` handle
//   carries its parameter values as part of its TYPE: the VIP's virtual-interface
//   handles are unparameterized (they take these defaults), so within one build
//   every apb_if instance the VIP binds to must share this width. Each build sets
//   the width once (timer: default 8; subsystem: +define+APB_ADDR_W=12), keeping
//   the whole simulation uniform.
// -----------------------------------------------------------------------------
`ifndef APB_ADDR_W
  `define APB_ADDR_W 8
`endif
`ifndef APB_DATA_W
  `define APB_DATA_W 32
`endif
interface apb_if #(parameter int ADDR_WIDTH = `APB_ADDR_W,
                   parameter int DATA_WIDTH = `APB_DATA_W);
  logic                  clk;
  logic                  rst_n;
  logic [ADDR_WIDTH-1:0] paddr;
  logic                  pwrite;
  logic                  penable;
  logic                  psel;
  logic [DATA_WIDTH-1:0] pwdata;
  logic [DATA_WIDTH-1:0] prdata;
  logic                  pready;
  logic                  pslverr;

  // APB3 slave modport (the DUT's view): master-driven in, slave-driven out.
  modport slave (
    input  clk, rst_n, paddr, pwrite, psel, penable, pwdata,
    output prdata, pready, pslverr
  );

  // APB3 master modport (an RTL initiator's view, e.g. the subsystem
  // interconnect driving a downstream slave). clk/rst_n are wired by the
  // enclosing top, so they are not part of this modport's direction set.
  modport master (
    output paddr, pwrite, psel, penable, pwdata,
    input  prdata, pready, pslverr
  );

  // ---- Simulation-only clocking blocks / modports (kept out of synthesis) ----
  // synopsys translate_off
  clocking m_drv_cb @(posedge clk);
    // default input #1step output #1;   // enable if skew tuning is needed
    input  prdata, pready, pslverr;
    output paddr, pwrite, psel, penable, pwdata;
  endclocking

  clocking m_mon_cb @(posedge clk);
    input  prdata, pready, pslverr, paddr, pwrite, psel, penable, pwdata;
  endclocking

  modport m_drv_mp (clocking m_drv_cb, input rst_n);
  modport m_mon_mp (clocking m_mon_cb, input rst_n);
  // synopsys translate_on
endinterface
