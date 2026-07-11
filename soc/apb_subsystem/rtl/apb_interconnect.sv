// -----------------------------------------------------------------------------
// apb_interconnect : 1-master -> 3-slave APB3 fabric (combinational)
//
//   Pure combinational address decode + downstream fan-out + response mux for
//   the apb_subsystem. No clocked logic and no state: APB is already a two-phase
//   handshake, so the fabric only needs to route SETUP/ACCESS transparently.
//
//   Upstream `up` is ADDR_WIDTH-wide (=12 in the subsystem); each downstream
//   dX carries the base-stripped local 8-bit offset up.paddr[7:0] (each timer
//   decodes its own low byte; the mem slave word-addresses within its page).
//
//   Address map (decode on the page field up.paddr[ADDR_WIDTH-1:8]):
//     page 0x0  (0x000..0x0FF) -> d0  (timer0)
//     page 0x1  (0x100..0x1FF) -> d1  (timer1)
//     page 0x2  (0x200..0x2FF) -> d2  (mem)
//     else                     -> unmapped: fabric returns pslverr in ACCESS
//
//   Response contract to `up`:
//     - mapped access   : route the selected slave's prdata/pready/pslverr.
//     - unmapped ACCESS  : pready=1, pslverr=1, prdata=0 (fabric self-responds).
//     - idle / unmapped SETUP : pready=0, pslverr=0, prdata=0.
//
//   Note: only the selected slave sees psel (dX.psel = up.psel & selX); the
//   two non-selected slaves stay quiescent and drive their responses to 0.
// -----------------------------------------------------------------------------
`default_nettype none

module apb_interconnect #(
    parameter int ADDR_WIDTH = 12,
    parameter int DATA_WIDTH = 32
) (
    apb_if.slave  up,   // upstream (subsystem-facing) : 12-bit paddr
    apb_if.master d0,   // downstream slave 0 : 8-bit paddr
    apb_if.master d1,   // downstream slave 1 : 8-bit paddr
    apb_if.master d2    // downstream slave 2 : 8-bit paddr
);

  // ---- Address partitioning ------------------------------------------------
  localparam int LOCAL_W = 8;                     // downstream local addr width
  localparam int PAGE_W  = ADDR_WIDTH - LOCAL_W;  // page field width (=4)

  logic [PAGE_W-1:0] page;
  logic              sel0, sel1, sel2;

  always_comb begin
    // ---- Decode ----------------------------------------------------------
    page = up.paddr[ADDR_WIDTH-1:LOCAL_W];
    sel0 = (page == PAGE_W'(0));
    sel1 = (page == PAGE_W'(1));
    sel2 = (page == PAGE_W'(2));

    // ---- Downstream fan-out (defaults, then per-slave psel) --------------
    // paddr/pwrite/pwdata/penable broadcast to all; only psel is qualified.
    d0.paddr   = up.paddr[LOCAL_W-1:0];
    d0.pwrite  = up.pwrite;
    d0.pwdata  = up.pwdata;
    d0.penable = up.penable;
    d0.psel    = up.psel & sel0;

    d1.paddr   = up.paddr[LOCAL_W-1:0];
    d1.pwrite  = up.pwrite;
    d1.pwdata  = up.pwdata;
    d1.penable = up.penable;
    d1.psel    = up.psel & sel1;

    d2.paddr   = up.paddr[LOCAL_W-1:0];
    d2.pwrite  = up.pwrite;
    d2.pwdata  = up.pwdata;
    d2.penable = up.penable;
    d2.psel    = up.psel & sel2;

    // ---- Response mux back to up (defaults-first, no latches) ------------
    up.prdata  = '0;
    up.pready  = 1'b0;
    up.pslverr = 1'b0;

    if (up.psel) begin
      if (sel0) begin
        up.prdata  = d0.prdata;
        up.pready  = d0.pready;
        up.pslverr = d0.pslverr;
      end else if (sel1) begin
        up.prdata  = d1.prdata;
        up.pready  = d1.pready;
        up.pslverr = d1.pslverr;
      end else if (sel2) begin
        up.prdata  = d2.prdata;
        up.pready  = d2.pready;
        up.pslverr = d2.pslverr;
      end else if (up.penable) begin
        // Unmapped access, ACCESS phase: fabric self-responds with error.
        up.prdata  = '0;
        up.pready  = 1'b1;
        up.pslverr = 1'b1;
      end
      // Unmapped SETUP phase falls through -> defaults (pready=0).
    end
    // Idle (up.psel==0) falls through -> defaults (all zero).
  end

endmodule

`default_nettype wire
