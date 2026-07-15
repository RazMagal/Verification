// -----------------------------------------------------------------------------
// apb_gpio : APB3 general-purpose parallel I/O peripheral  (spec v1.0)
//
//   DATA_WIDTH parallel pins exposed to an external pad ring as
//   gpio_out / gpio_oe (driven) and gpio_in (sampled). A 2-flop input
//   synchronizer feeds a per-pin rising-edge interrupt with a sticky,
//   write-1-to-clear status register. Connects to the shared VIP interface
//   `apb_if` via its `slave` modport.
//
//   Clocking / reset (per spec §1, §3.4):
//     - Single clock  : apb.clk (rising edge).
//     - Reset         : apb.rst_n, active-low, ASYNC assert / SYNC deassert.
//                       Every register, din_sync (and its meta stage) and irq
//                       reset to 0.
//
//   APB timing (per spec §1, §3):
//     - Two-phase transfer SETUP (psel,!penable) -> ACCESS (psel,penable).
//     - No wait states: pready is a pure combinational 1 in the ACCESS phase,
//       so the response (pready/prdata/pslverr) is a combinational function of
//       the bus + register state -- there is NO slave-side FSM here.
//     - Writes commit in the ACCESS phase (psel & penable & pwrite).
//     - pslverr for any address not in {0x00,0x04,0x08,0x0C,0x10}; on pslverr
//       a write has no effect and a read returns prdata=0. A (legal) write to
//       the RO DATA_IN register is silently dropped WITHOUT pslverr.
//
//   Pin model (spec §1): this is a GPIO *core* -- no internal tri-state and no
//   internal loopback. gpio_in reflects only the outside world; the external
//   pad uses gpio_oe[i] to decide whether to drive gpio_out[i].
//
//   Address decode assumption: this IP decodes its full `apb.paddr` as the
//   local byte offset (spec §1 fixes ADDR_WIDTH=8). In an interconnect the
//   base-stripped local offset is presented to each slave.
// -----------------------------------------------------------------------------
`default_nettype none

module apb_gpio #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32   // also NPINS
) (
    apb_if.slave                  apb,
    input  logic [DATA_WIDTH-1:0] gpio_in,   // external pin inputs
    output logic [DATA_WIDTH-1:0] gpio_out,  // pin output values (to pad)
    output logic [DATA_WIDTH-1:0] gpio_oe,   // per-pin output enable (to pad)
    output logic                  irq        // active-high level interrupt
);

  // ---- Register byte offsets (spec §2) -------------------------------------
  localparam logic [ADDR_WIDTH-1:0] DATA_OUT_OFF   = 'h00;  // RW
  localparam logic [ADDR_WIDTH-1:0] DATA_IN_OFF    = 'h04;  // RO
  localparam logic [ADDR_WIDTH-1:0] DIR_OFF        = 'h08;  // RW
  localparam logic [ADDR_WIDTH-1:0] INT_STATUS_OFF = 'h0C;  // RW1C
  localparam logic [ADDR_WIDTH-1:0] INT_EN_OFF     = 'h10;  // RW

  // ---- Architectural state (fixed names, spec §4) --------------------------
  logic [DATA_WIDTH-1:0] dout_q;     // DATA_OUT   register  -> gpio_out
  logic [DATA_WIDTH-1:0] dir_q;      // DIR        register  -> gpio_oe
  logic [DATA_WIDTH-1:0] inten_q;    // INT_EN     register
  logic [DATA_WIDTH-1:0] intstat_q;  // INT_STATUS register (sticky, RW1C)
  logic [DATA_WIDTH-1:0] din_sync;   // 2-FF synchronized input (DATA_IN value)

  // First synchronizer stage (metastability catch). Not a software-visible
  // register; din_sync is stage 2, the clean value the spec exposes.
  logic [DATA_WIDTH-1:0] din_meta;

  // ---- Combinational bus decode / events -----------------------------------
  logic                  addr_legal;   // paddr is a mapped register
  logic                  wr_en;        // legal register write committing now
  logic                  wr_intstat;   // legal write targeting INT_STATUS
  logic [DATA_WIDTH-1:0] din_rise;     // per-pin rising edge on din_sync (0->1)
  logic [DATA_WIDTH-1:0] intstat_clr;  // per-pin W1C clear request (SW)

  assign addr_legal = (apb.paddr inside
      {DATA_OUT_OFF, DATA_IN_OFF, DIR_OFF, INT_STATUS_OFF, INT_EN_OFF});

  // Register write strobe: only for legal addresses (illegal -> pslverr, no
  // effect). v1.0 has no wait states (pready is always 1 in ACCESS), so this is
  // the completing beat. If a PREADY wait hook is added, gate with && apb.pready
  // so a write commits exactly once, on the completing beat.
  assign wr_en      = apb.psel && apb.penable && apb.pwrite && addr_legal;
  assign wr_intstat = wr_en && (apb.paddr == INT_STATUS_OFF);

  // Rising edge on the synchronized input (spec §3.3): din_sync is about to go
  // 0->1 when stage-2 is still 0 but stage-1 (din_meta) is already 1. Evaluated
  // from current-cycle state, so intstat is set on the same edge din_sync
  // reaches 1 -- analogous to the timer's combinational `timeout` set.
  assign din_rise    = din_meta & ~din_sync;

  // W1C clear mask: pwdata bits on a completing INT_STATUS write (else none).
  assign intstat_clr = wr_intstat ? apb.pwdata : '0;

  // ---- Sequential: synchronizer + registers (spec §3) ----------------------
  // async assert / sync deassert, active-low.
  always_ff @(posedge apb.clk or negedge apb.rst_n) begin
    if (!apb.rst_n) begin
      dout_q    <= '0;
      dir_q     <= '0;
      inten_q   <= '0;
      intstat_q <= '0;
      din_meta  <= '0;
      din_sync  <= '0;
    end else begin
      // --- 2-FF input synchronizer (spec §3.2) ----------------------------
      din_meta <= gpio_in;
      din_sync <= din_meta;

      // --- APB register writes (RO and W1C handled separately) ------------
      if (wr_en) begin
        unique case (apb.paddr)
          DATA_OUT_OFF:   dout_q  <= apb.pwdata;
          DIR_OFF:        dir_q   <= apb.pwdata;
          INT_EN_OFF:     inten_q <= apb.pwdata;
          INT_STATUS_OFF: /* RW1C : handled in the INT_STATUS block below   */ ;
          DATA_IN_OFF:    /* RO   : write silently dropped (no pslverr)      */ ;
          default:        /* unreachable: wr_en implies addr_legal          */ ;
        endcase
      end

      // --- INT_STATUS : per-pin sticky, RW1C (spec §3.3) ------------------
      // Clear (SW W1C) is applied first, then HW set (rising edge) ORs in, so
      // a same-cycle edge-vs-W1C race on a bit leaves it SET (HW-set-wins).
      intstat_q <= (intstat_q & ~intstat_clr) | din_rise;
    end
  end

  // ---- Output path (spec §3.1) : all bits driven unconditionally -----------
  assign gpio_out = dout_q;
  assign gpio_oe  = dir_q;

  // ---- Combinational APB response (single-cycle, no wait states) -----------
  always_comb begin
    // Default drives on every path -> no inferred latches.
    apb.prdata  = '0;
    apb.pready  = 1'b0;
    apb.pslverr = 1'b0;

    if (apb.psel && apb.penable) begin      // ACCESS phase
      apb.pready = 1'b1;                     // v1.0: always ready in ACCESS
      if (!addr_legal) begin
        apb.pslverr = 1'b1;                  // illegal address; prdata stays 0
      end else if (!apb.pwrite) begin        // legal read
        unique case (apb.paddr)
          DATA_OUT_OFF:   apb.prdata = dout_q;
          DATA_IN_OFF:    apb.prdata = din_sync;   // synchronized live sample
          DIR_OFF:        apb.prdata = dir_q;
          INT_STATUS_OFF: apb.prdata = intstat_q;
          INT_EN_OFF:     apb.prdata = inten_q;
          default:        /* unreachable: guarded by addr_legal */ ;
        endcase
      end
    end
  end

  // ---- Interrupt output : purely combinational level (spec §3.3) -----------
  assign irq = |(intstat_q & inten_q);

endmodule

`default_nettype wire
