// -----------------------------------------------------------------------------
// apb_timer : APB3 programmable down-counter peripheral  (spec v1.0)
//
//   A prescaled 32-bit down-counter with a sticky, level-sensitive interrupt.
//   Connects to the shared VIP interface `apb_if` via its `slave` modport.
//
//   Clocking / reset (per spec §1, §3):
//     - Single clock  : apb.clk (rising edge).
//     - Reset         : apb.rst_n, active-low, ASYNC assert / SYNC deassert.
//                       Every register/counter resets to 0.
//
//   APB timing (per spec §1, §4):
//     - Two-phase transfer SETUP (psel,!penable) -> ACCESS (psel,penable).
//     - No wait states in v1.0: the slave asserts pready=1 for exactly one
//       cycle in the ACCESS phase. The response (pready/prdata/pslverr) is a
//       pure combinational function of the bus + register state, so there is
//       NO slave-side FSM to model here (a wait-state hook would add one).
//     - Writes commit in the ACCESS phase (psel & penable & pwrite).
//     - pslverr for any address not in {0x00,0x04,0x08,0x0C,0x10}; on pslverr
//       a write has no effect and a read returns prdata=0. A (legal) write to
//       the RO VALUE register is silently dropped WITHOUT pslverr.
//
//   Address decode assumption: this IP decodes its full `apb.paddr` as the
//   local byte offset (spec §1 fixes ADDR_WIDTH=8). In the apb_subsystem the
//   interconnect presents the base-stripped local offset to each timer.
// -----------------------------------------------------------------------------
`default_nettype none

module apb_timer #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
) (
    apb_if.slave apb,
    output logic irq
);

  // ---- Register byte offsets (spec §2) -------------------------------------
  localparam logic [ADDR_WIDTH-1:0] CTRL_OFF     = 'h00;
  localparam logic [ADDR_WIDTH-1:0] LOAD_OFF     = 'h04;
  localparam logic [ADDR_WIDTH-1:0] VALUE_OFF    = 'h08;
  localparam logic [ADDR_WIDTH-1:0] STATUS_OFF   = 'h0C;
  localparam logic [ADDR_WIDTH-1:0] PRESCALE_OFF = 'h10;

  localparam int PRESCALE_W = 8;  // PRESCALE.[7:0] (spec §2.5)

  // ---- Architectural state -------------------------------------------------
  logic                    ctrl_en;       // CTRL[0] EN
  logic                    ctrl_mode;     // CTRL[1] MODE (0=one-shot,1=periodic)
  logic                    ctrl_irqen;    // CTRL[2] IRQ_EN
  logic [DATA_WIDTH-1:0]   load_reg;      // LOAD
  logic [PRESCALE_W-1:0]   prescale_reg;  // PRESCALE[7:0]
  logic                    status_irq;    // STATUS[0] IRQ (RW1C, sticky)
  logic [DATA_WIDTH-1:0]   cnt;           // live down-counter (read via VALUE)
  logic [PRESCALE_W-1:0]   psc;           // prescale sub-counter (0..PRESCALE)

  // ---- Combinational bus decode / events -----------------------------------
  logic addr_legal;    // paddr is a mapped register
  logic wr_en;         // legal register write committing this cycle
  logic wr_status;     // legal write targeting STATUS
  logic start_event;   // CTRL.EN driven 0->1 by this write (start)
  logic timeout;       // a tick that takes cnt to 0 (fires the interrupt)

  assign addr_legal =
      (apb.paddr inside {CTRL_OFF, LOAD_OFF, VALUE_OFF, STATUS_OFF, PRESCALE_OFF});

  // Register write strobe: only for legal addresses (illegal -> pslverr, no effect).
  // NOTE: v1.0 has no wait states (pready is always 1 in ACCESS), so this is the
  // completing beat. If a PREADY wait hook is ever added, gate this with pready
  // (&& apb.pready) so a write commits exactly once, on the completing beat.
  assign wr_en     = apb.psel && apb.penable && apb.pwrite && addr_legal;
  assign wr_status = wr_en && (apb.paddr == STATUS_OFF);

  // Start = a CTRL write that turns EN on while it is currently off (0->1 edge).
  assign start_event = wr_en && (apb.paddr == CTRL_OFF) && apb.pwdata[0] && !ctrl_en;

  // Timeout = while enabled, on a tick boundary (psc==PRESCALE), when cnt is
  // about to reach 0 (cnt==1) or is already 0 (the LOAD==0 immediate case).
  assign timeout = ctrl_en && (psc == prescale_reg) &&
                   ((cnt == '0) || (cnt == DATA_WIDTH'(1)));

  // ---- Sequential: registers + counter (spec §3) ---------------------------
  // async assert / sync deassert, active-low.
  always_ff @(posedge apb.clk or negedge apb.rst_n) begin
    if (!apb.rst_n) begin
      ctrl_en      <= 1'b0;
      ctrl_mode    <= 1'b0;
      ctrl_irqen   <= 1'b0;
      load_reg     <= '0;
      prescale_reg <= '0;
      status_irq   <= 1'b0;
      cnt          <= '0;
      psc          <= '0;
    end else begin
      // --- APB register writes (control/config; RO and W1C handled below) ---
      if (wr_en) begin
        unique case (apb.paddr)
          CTRL_OFF: begin
            ctrl_en    <= apb.pwdata[0];  // may be re-cleared by one-shot auto-clear below
            ctrl_mode  <= apb.pwdata[1];
            ctrl_irqen <= apb.pwdata[2];
          end
          LOAD_OFF:     load_reg     <= apb.pwdata;
          PRESCALE_OFF: prescale_reg <= apb.pwdata[PRESCALE_W-1:0];
          STATUS_OFF:   /* W1C handled in the STATUS.IRQ block below */ ;
          VALUE_OFF:    /* RO : write silently dropped (no pslverr)    */ ;
          default:      /* unreachable: wr_en implies addr_legal       */ ;
        endcase
      end

      // --- Prescaler / down-counter ---------------------------------------
      // start_event and the counting branch are mutually exclusive: start_event
      // requires ctrl_en==0, so no tick can collide with a (re)load.
      if (start_event) begin
        cnt <= load_reg;                    // (re)load on EN 0->1
        psc <= '0;                          // restart the prescaler
      end else if (ctrl_en) begin
        if (psc == prescale_reg) begin      // tick boundary (every N+1 cycles)
          psc <= '0;
          if (timeout) begin
            if (ctrl_mode) cnt <= load_reg; // periodic: reload, keep running
            else           cnt <= '0;       // one-shot : hold at 0
          end else begin
            cnt <= cnt - 1'b1;              // normal decrement
          end
        end else begin
          psc <= psc + 1'b1;                // sub-tick
        end
      end

      // --- One-shot auto-clear of EN on timeout ---------------------------
      // Placed after the CTRL write so HW auto-clear wins a same-cycle race
      // with a software EN=1 write (documented, race-free choice).
      if (timeout && !ctrl_mode) ctrl_en <= 1'b0;

      // --- STATUS.IRQ : sticky, RW1C --------------------------------------
      // HW set (timeout) has priority over a same-cycle SW write-1-to-clear.
      if (timeout)                         status_irq <= 1'b1;   // HW set wins
      else if (wr_status && apb.pwdata[0]) status_irq <= 1'b0;   // W1C
    end
  end

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
          CTRL_OFF: begin
            apb.prdata[0] = ctrl_en;
            apb.prdata[1] = ctrl_mode;
            apb.prdata[2] = ctrl_irqen;      // [31:3] reserved read 0 (default)
          end
          LOAD_OFF:     apb.prdata                  = load_reg;
          VALUE_OFF:    apb.prdata                  = cnt;
          STATUS_OFF:   apb.prdata[0]               = status_irq; // [31:1] read 0
          PRESCALE_OFF: apb.prdata[PRESCALE_W-1:0]  = prescale_reg;
          default:      /* unreachable: guarded by addr_legal */ ;
        endcase
      end
    end
  end

  // ---- Interrupt output : purely combinational level (spec §3) -------------
  assign irq = ctrl_irqen & status_irq;

endmodule

`default_nettype wire
