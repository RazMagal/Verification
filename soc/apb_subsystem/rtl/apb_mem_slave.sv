// -----------------------------------------------------------------------------
// apb_mem_slave : simple APB3 word-addressed memory slave
//
//   A single-cycle SRAM-style APB3 slave used inside apb_subsystem at page 0x2.
//   Word-addressed store of depth 2**(ADDR_WIDTH-2), indexed by the word-aligned
//   local byte address apb.paddr[ADDR_WIDTH-1:2] (bits [1:0] are the byte lanes
//   and are ignored - all local accesses are treated as 32-bit word accesses).
//
//   Clocking / reset:
//     - Single clock : apb.clk (rising edge).
//     - Reset        : apb.rst_n, active-low, async assert / sync deassert.
//       The APB response (prdata/pready/pslverr) is purely combinational, so
//       there are no registered outputs to reset. The memory array is a wide
//       datapath and is intentionally NOT reset (typical RAM: undefined until
//       written; reads of never-written words return the array's power-on X in
//       sim, 0 after the first write). No control/state FSM exists here.
//
//   APB timing (matches apb_timer's response style, no wait states):
//     - Two-phase SETUP (psel,!penable) -> ACCESS (psel,penable).
//     - pready=1 for exactly one cycle in the ACCESS phase.
//     - pslverr is NEVER asserted: every local address maps to a valid word
//       (the interconnect has already range-checked page 0x2).
//     - Reads return the stored word combinationally; writes commit at the
//       clock edge in the ACCESS phase. A read of a word being written in the
//       same cycle returns the OLD value (write-after-read), which is race-free.
// -----------------------------------------------------------------------------
`default_nettype none

module apb_mem_slave #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    apb_if.slave apb
);

  // ---- Geometry ------------------------------------------------------------
  localparam int IDX_W = ADDR_WIDTH - 2;          // word-index width
  localparam int DEPTH = 2 ** IDX_W;              // number of words

  // ---- Storage (wide datapath: not reset) ----------------------------------
  logic [DATA_WIDTH-1:0] mem [DEPTH];

  // ---- Word index (drop byte-lane bits [1:0]) ------------------------------
  logic [IDX_W-1:0] widx;
  logic             wr_en;

  assign widx  = apb.paddr[ADDR_WIDTH-1:2];
  assign wr_en = apb.psel && apb.penable && apb.pwrite;

  // ---- Sequential : single-cycle write commit in the ACCESS phase ----------
  // No reset on the memory array (see header). Only the write is sequential.
  always_ff @(posedge apb.clk) begin
    if (wr_en) begin
      mem[widx] <= apb.pwdata;
    end
  end

  // ---- Combinational APB response (single-cycle, no wait states) -----------
  always_comb begin
    // Defaults on every path -> no inferred latches.
    apb.prdata  = '0;
    apb.pready  = 1'b0;
    apb.pslverr = 1'b0;                 // this slave never errors

    if (apb.psel && apb.penable) begin  // ACCESS phase
      apb.pready = 1'b1;                 // always ready in ACCESS
      if (!apb.pwrite) begin
        apb.prdata = mem[widx];         // read returns the stored word
      end
    end
  end

endmodule

`default_nettype wire
