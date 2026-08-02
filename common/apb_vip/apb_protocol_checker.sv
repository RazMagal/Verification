`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// apb_protocol_checker : reusable, bindable APB3 protocol assertions (plain SVA)
//
//   No UVM dependency: this is a self-contained module of concurrent SVA that
//   is `bind`-ed onto the shared `apb_if` so protocol compliance is checked on
//   every APB agent instance (standalone timer and subsystem alike). Because it
//   is plain SVA it also compiles in a formal-verification flow.
//
//   Intended bind (place e.g. in the tb top / a bind file):
//
//     bind apb_if apb_protocol_checker #(
//         .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
//     ) u_apb_chk (
//         .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable),
//         .pwrite(pwrite), .pready(pready), .pslverr(pslverr),
//         .paddr(paddr), .pwdata(pwdata), .prdata(prdata)
//     );
//
//   Assumptions: single-clock APB3, active-low rst_n, checks disabled in reset.
//   Wait states are tolerated (properties key off pready), even though the
//   apb_timer v1.0 never inserts any.
//
//   The parameter DEFAULTS below are the shared `APB_ADDR_W / `APB_DATA_W macros
//   (apb_width_defines.svh), not literals, so a bind that forgets the overrides
//   still gets the build's real widths instead of a stale 8/32. Every bind in
//   this repo passes the enclosing apb_if's own ADDR_WIDTH/DATA_WIDTH anyway.
// -----------------------------------------------------------------------------
`include "apb_width_defines.svh"

module apb_protocol_checker #(
    parameter int ADDR_WIDTH = `APB_ADDR_W,
    parameter int DATA_WIDTH = `APB_DATA_W
) (
    input logic                  clk,
    input logic                  rst_n,
    input logic                  psel,
    input logic                  penable,
    input logic                  pwrite,
    input logic                  pready,
    input logic                  pslverr,
    input logic [ADDR_WIDTH-1:0] paddr,
    input logic [DATA_WIDTH-1:0] pwdata,
    input logic [DATA_WIDTH-1:0] prdata
);

  // ---- Handy phase expressions --------------------------------------------
  // SETUP  : psel & !penable      ACCESS : psel & penable
  // A transfer completes on the ACCESS cycle in which pready is high.
  wire access_done = psel && penable && pready;

  // 1) SETUP must be followed by ACCESS: penable rises the cycle after a SETUP.
  property p_setup_to_access;
    @(posedge clk) disable iff (!rst_n)
      (psel && !penable) |=> (psel && penable);
  endproperty
  a_setup_to_access : assert property (p_setup_to_access)
      else $error("APB: SETUP (psel,!penable) not followed by ACCESS (psel,penable)");

  // 2) Control/address (and write data) are stable once selected until the
  //    ACCESS cycle completes (pready). Holds across any wait states.
  property p_stable_until_ready;
    @(posedge clk) disable iff (!rst_n)
      (psel && !access_done) |=>
        (psel && $stable(paddr) && $stable(pwrite) &&
         (!pwrite || $stable(pwdata)));
  endproperty
  a_stable_until_ready : assert property (p_stable_until_ready)
      else $error("APB: paddr/pwrite/pwdata/psel changed before transfer completed");

  // 3) penable is never asserted without psel.
  property p_penable_needs_psel;
    @(posedge clk) disable iff (!rst_n)
      penable |-> psel;
  endproperty
  a_penable_needs_psel : assert property (p_penable_needs_psel)
      else $error("APB: penable asserted while psel deasserted");

  // 4) After a completed ACCESS, penable deasserts the next cycle
  //    (either back to IDLE or to the SETUP of the next transfer).
  property p_penable_drops_after_access;
    @(posedge clk) disable iff (!rst_n)
      access_done |=> !penable;
  endproperty
  a_penable_drops_after_access : assert property (p_penable_drops_after_access)
      else $error("APB: penable still asserted the cycle after a completed ACCESS");

  // 5) pslverr may only be asserted with pready in an ACCESS cycle.
  property p_pslverr_in_access;
    @(posedge clk) disable iff (!rst_n)
      pslverr |-> (psel && penable && pready);
  endproperty
  a_pslverr_in_access : assert property (p_pslverr_in_access)
      else $error("APB: pslverr asserted outside a completed ACCESS cycle");

  // ---- Coverage : make sure the interesting transfers actually happen ------
  c_write_ok  : cover property (@(posedge clk) disable iff (!rst_n)
                    access_done &&  pwrite && !pslverr);
  c_read_ok   : cover property (@(posedge clk) disable iff (!rst_n)
                    access_done && !pwrite && !pslverr);
  c_slverr    : cover property (@(posedge clk) disable iff (!rst_n)
                    access_done && pslverr);

endmodule
