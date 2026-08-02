// -----------------------------------------------------------------------------
// photonic_ring_tuner : silicon-photonic microring resonance-lock controller
//                       on an APB3 slave port  (spec v1.0)
//
//   Drives a thermal (heater) DAC and samples a monitor-photodiode ADC, and
//   parks the ring's optical resonance on the laser line in two phases
//   (spec §0, §3.2):
//     1. Coarse sweep  - ramp dac_q across the full DAC range and remember the
//                        code that produced the most light
//                        (S_SWEEP_WAIT / S_SWEEP_SAMP, spec §3.3).
//     2. Fine dither   - probe one dither step above and one below the centre
//                        code, move toward the brighter probe, and declare lock
//                        after LOCK_N consecutive at-peak iterations
//                        (S_HI_* / S_LO_* / S_UPDATE, spec §3.4).
//   The optics are outside this module: adc_code is free-running and always
//   valid (spec §1) -- there is no conversion handshake to wait on.
//
//   Clocking / reset (spec §1, §3.6):
//     - Single clock  : apb.clk (rising edge).
//     - Reset         : apb.rst_n, active-low, ASYNC assert / SYNC deassert.
//                       Every register takes its spec §2 reset value,
//                       state_q <- S_IDLE, and dac_code drives 0.
//
//   APB timing (spec §1, §2) -- identical handling to apb_gpio / apb_timer:
//     - Two-phase transfer SETUP (psel,!penable) -> ACCESS (psel,penable).
//     - No wait states: pready is a pure combinational 1 in the ACCESS phase,
//       so the response (pready/prdata/pslverr) is a combinational function of
//       the bus + register state -- there is NO slave-side FSM here.
//     - Writes commit in the ACCESS phase (psel & penable & pwrite).
//     - pslverr for any offset not in {0x00,0x04,0x08,0x0C,0x10,0x14,0x18}; on
//       pslverr a write has no effect and a read returns prdata=0. A (legal)
//       write to the RO DAC/PD registers, or to a RO field of STATUS, is
//       silently dropped WITHOUT pslverr.
//
//   FSM encoding (spec §3.2): state_q is a plain `logic [2:0]` with localparam
//   encodings -- deliberately NOT an enum -- so the bound SVA can decode it
//   without importing a type. All eight encodings are legal/reachable.
//
//   Internal signal names are fixed by spec §4 (the bound SVA references them
//   by name); do not rename state_q, dac_q, pd_q, p_hi_q, p_lo_q, best_adc_q,
//   best_code_q, lock_cnt_q, locked_q, rail_err_q, sweep_err_q, en_q, dither_q,
//   sweep_q, settle_q, thresh_q, minpow_q or settle_cnt_q.
//
//   Interpretations of points the spec leaves open (flagged deliberately):
//     - S_IDLE is left on a RISING EDGE of CTRL.EN (spec §3.1: "0 -> 1 starts a
//       fresh acquisition"). A sweep that ended in SWEEP_ERR therefore parks in
//       S_IDLE (spec §3.3) until software re-arms EN 0->1, instead of looping
//       on a dark ring. The edge is taken off the REGISTERED en_q so the FSM
//       never leaves S_IDLE while en_q is still 0 (keeps spec §5.5 exact).
//     - pd_q tracks the most recent ADC sample in EVERY sample state (spec §2
//       "most recent ADC sample"), not only the sweep samples of spec §3.3 --
//       otherwise PD freezes at the last sweep point while the loop is locked
//       and the spec §5.3 power check reads a stale value.
//     - DATA_WIDTH is effectively fixed at 32 by the spec §2 field layout
//       (LOCK_CFG.MINPOW lives in [31:16]); ADDR_WIDTH=8 per spec §1. Both
//       that and the width of the CONNECTED apb_if are checked at elaboration.
//     - "Holds dac_q" (spec §3.1) is implemented as a LOOP ACTUATION GATE on
//       en_d, not merely as a post-hoc clear of the lock state: on the cycle
//       CTRL.EN drops, no state that MOVES the loop (dac_q, sweep bookkeeping,
//       lock counter) updates and no sticky error may be latched by loop
//       activity. Passive ADC capture into pd_q/p_hi_q/p_lo_q is not gated.
//
//   Address decode assumption: this IP decodes its full `apb.paddr` as the
//   local byte offset (spec §1 fixes ADDR_WIDTH=8). In an interconnect the
//   base-stripped local offset is presented to each slave.
// -----------------------------------------------------------------------------
`default_nettype none

module photonic_ring_tuner #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32,   // APB data width
    parameter int DAC_WIDTH  = 12,   // heater DAC resolution
    parameter int ADC_WIDTH  = 12,   // photodiode ADC resolution
    parameter int LOCK_N     = 4     // consecutive at-peak iterations to lock
) (
    apb_if.slave                 apb,
    input  logic [ADC_WIDTH-1:0] adc_code,  // photodiode reading (free-running)
    output logic [DAC_WIDTH-1:0] dac_code,  // heater DAC drive
    output logic                 locked     // active-high level: loop is locked
);

  // ---- Elaboration-time parameter checks -----------------------------------
  // These are ELABORATION system tasks (IEEE 1800 §20.11), not `initial`
  // blocks: they fire at compile/elaborate time, cost nothing at run time and
  // are ignored by synthesis. A degenerate parameter must fail loudly here
  // rather than as a cryptic error deep inside the body (or, worse, silently).
  //
  //   - LOCK_N == 0 makes $clog2(LOCK_N+1) == 0, i.e. lock_cnt_q is declared
  //     `logic [-1:0]` -- an elaboration error a long way from its cause.
  //   - DAC_WIDTH / ADC_WIDTH of 0 are degenerate for the same reason, and
  //     neither may exceed the bus, since DAC/PD are read as prdata[W-1:0].
  //   - ADDR_WIDTH must span the largest mapped offset (PD_OFF = 'h18).
  //   - DATA_WIDTH is fixed at 32 by the spec §2 field layout: LOCK_CFG.MINPOW
  //     lives in [31:16] and STEP.SWEEP in [15:8].
  //   - ADC_WIDTH is additionally capped at 19 by the MINPOW RESET VALUE, which
  //     is a FRACTION OF FULL SCALE (full-scale/16 = 2**(ADC_WIDTH-4), see
  //     MINPOW_RST below) while LOCK_CFG.MINPOW is a 16-bit field: at
  //     ADC_WIDTH = 20 that reset needs 2**16 and no longer fits, and neither
  //     does any other meaningful fraction of full scale, so the register map
  //     itself is unfit for such a converter. That is REJECTED here rather than
  //     silently clamped, because a clamped MINPOW is a false-lock guard that
  //     has quietly stopped being one -- the PERMISSIVE failure direction, the
  //     dangerous one (spec §2 note, §3.4). MINPOW_RST clamps as well, so the
  //     expression is total for every width even where nothing can $fatal (the
  //     DV's RAL elaborates the same formula from the same ADC_WIDTH).
  //
  // The two BUS-width checks are deliberately SEPARATE from the DATA_WIDTH /
  // ADDR_WIDTH parameter checks: this module's parameters and the widths of the
  // apb_if instance it is connected to are independent, and nothing forces them
  // to agree. If the interface is narrower than 32 bits, `apb.prdata[31:16] =
  // minpow_q` (and the MINPOW half of a LOCK_CFG write) silently mis-decodes.
  localparam int BUS_DATA_W = $bits(apb.pwdata);
  localparam int BUS_ADDR_W = $bits(apb.paddr);

  if (LOCK_N < 1)
    $fatal(1, "photonic_ring_tuner: LOCK_N must be >= 1 (got %0d)", LOCK_N);

  if (DAC_WIDTH < 1 || DAC_WIDTH > DATA_WIDTH)
    $fatal(1, "photonic_ring_tuner: DAC_WIDTH must be 1..DATA_WIDTH (got %0d)",
           DAC_WIDTH);

  if (ADC_WIDTH < 1 || ADC_WIDTH > DATA_WIDTH)
    $fatal(1, "photonic_ring_tuner: ADC_WIDTH must be 1..DATA_WIDTH (got %0d)",
           ADC_WIDTH);

  if (ADC_WIDTH > 19)
    $fatal(1, {"photonic_ring_tuner: ADC_WIDTH must be <= 19: the MINPOW reset is ",
               "full-scale/16 = 2**(ADC_WIDTH-4) and LOCK_CFG.MINPOW is 16 bits ",
               "(spec 2), so 20 bits would need 2**16 (got %0d)"}, ADC_WIDTH);

  if (ADDR_WIDTH < 5)
    $fatal(1, "photonic_ring_tuner: ADDR_WIDTH must be >= 5 to map 0x00..0x18 (got %0d)",
           ADDR_WIDTH);

  if (DATA_WIDTH != 32)
    $fatal(1, "photonic_ring_tuner: DATA_WIDTH must be 32 (spec 2 field layout, got %0d)",
           DATA_WIDTH);

  if (BUS_DATA_W != 32)
    $fatal(1, "photonic_ring_tuner: connected apb_if DATA_WIDTH must be 32 (got %0d)",
           BUS_DATA_W);

  if (BUS_ADDR_W != ADDR_WIDTH)
    $fatal(1, "photonic_ring_tuner: connected apb_if ADDR_WIDTH (%0d) != ADDR_WIDTH (%0d)",
           BUS_ADDR_W, ADDR_WIDTH);

  // ---- Register byte offsets (spec §2) -------------------------------------
  localparam logic [ADDR_WIDTH-1:0] CTRL_OFF     = 'h00;  // RW
  localparam logic [ADDR_WIDTH-1:0] STEP_OFF     = 'h04;  // RW
  localparam logic [ADDR_WIDTH-1:0] SETTLE_OFF   = 'h08;  // RW
  localparam logic [ADDR_WIDTH-1:0] LOCK_CFG_OFF = 'h0C;  // RW
  localparam logic [ADDR_WIDTH-1:0] STATUS_OFF   = 'h10;  // mixed RO / W1C
  localparam logic [ADDR_WIDTH-1:0] DAC_OFF      = 'h14;  // RO
  localparam logic [ADDR_WIDTH-1:0] PD_OFF       = 'h18;  // RO

  // ---- Register reset values (spec §2) -------------------------------------
  localparam logic  [7:0] DITHER_RST = 8'h04;    // STEP[7:0]      of 0x0000_2004
  localparam logic  [7:0] SWEEP_RST  = 8'h20;    // STEP[15:8]     of 0x0000_2004
  localparam logic [15:0] SETTLE_RST = 16'h0020; // SETTLE[15:0]

  // THRESH deliberately does NOT scale with ADC_WIDTH: it separates a real
  // optical gradient from the QUANTIZATION NOISE FLOOR, which is ~0.5 LSB at
  // any converter width, so it is an absolute LSB count (spec §2, §3.4).
  localparam logic [15:0] THRESH_RST = 16'h0008; // LOCK_CFG[15:0], absolute

  // MINPOW DOES scale: it is a FRACTION OF THE EXPECTED PEAK (spec §2, §3.3,
  // §3.4), so the reset is full-scale/16 = 2**(ADC_WIDTH-4) -- exactly 0x0100
  // at the default ADC_WIDTH = 12, which is what the 0x0100 in "reset
  // 0x0100_0008" always meant. Clamped at both ends so the expression is total:
  //   * floored at 1 -- 2**(ADC_WIDTH-4) rounds to 0 below ADC_WIDTH = 5, and a
  //     MINPOW of 0 is no false-lock guard at all (a dark ring qualifies);
  //   * capped at the 16-bit field -- unreachable in an elaborable build, since
  //     ADC_WIDTH > 19 $fatals above; the cap is what makes the localparam
  //     well-defined rather than a second opinion about legality.
  // Both clamps stay <= 2**ADC_WIDTH - 1, so the reset MINPOW is never above
  // full scale, i.e. never unreachable for the sweep (spec §3.3 SWEEP_ERR).
  localparam logic [15:0] MINPOW_RST = (ADC_WIDTH <  5) ? 16'h0001
                                     : (ADC_WIDTH > 19) ? 16'hFFFF
                                     : 16'(1 << (ADC_WIDTH - 4));

  // ---- FSM state encoding (spec §3.2, fixed for the bound SVA) -------------
  localparam logic [2:0] S_IDLE       = 3'd0;  // wait for EN
  localparam logic [2:0] S_SWEEP_WAIT = 3'd1;  // settle at the sweep point
  localparam logic [2:0] S_SWEEP_SAMP = 3'd2;  // sample / update best / advance
  localparam logic [2:0] S_HI_WAIT    = 3'd3;  // settle at dac_q + dither
  localparam logic [2:0] S_HI_SAMP    = 3'd4;  // capture p_hi_q
  localparam logic [2:0] S_LO_WAIT    = 3'd5;  // settle at dac_q - dither
  localparam logic [2:0] S_LO_SAMP    = 3'd6;  // capture p_lo_q
  localparam logic [2:0] S_UPDATE     = 3'd7;  // compare probes / move / lock

  // ---- Derived widths ------------------------------------------------------
  localparam int STEP_W = 8;  // STEP.DITHER / STEP.SWEEP field width (spec §2)

  // DAC rails (spec §1): no programmable limits in v1.0.
  localparam logic [DAC_WIDTH-1:0] DAC_MAX = {DAC_WIDTH{1'b1}};
  localparam logic [DAC_WIDTH-1:0] DAC_MIN = '0;

  // Width for DAC +/- step intermediates: one bit wider than the widest
  // operand, so dac_q + step can NEVER overflow before it is compared against
  // DAC_MAX (spec §3.2 "computed with enough width", spec §3.4 saturation).
  localparam int SUM_W = ((DAC_WIDTH > STEP_W) ? DAC_WIDTH : STEP_W) + 1;

  // Width for optical-power comparisons: ADC samples (ADC_WIDTH) are compared
  // against / summed with the 16-bit THRESH and MINPOW fields, so p_lo + THRESH
  // cannot overflow either.
  localparam int PWR_W = ((ADC_WIDTH > 16) ? ADC_WIDTH : 16) + 1;

  localparam int LOCK_CNT_W = $clog2(LOCK_N + 1);  // spec §4 lock_cnt_q width

  // ---- Architectural state (fixed names, spec §4) --------------------------
  logic            [2:0] state_q;       // FSM state, encoded per spec §3.2
  logic  [DAC_WIDTH-1:0] dac_q;         // centre code (the DAC register)
  logic  [ADC_WIDTH-1:0] pd_q;          // last ADC sample (the PD register)
  logic  [ADC_WIDTH-1:0] p_hi_q;        // upper probe sample
  logic  [ADC_WIDTH-1:0] p_lo_q;        // lower probe sample
  logic  [ADC_WIDTH-1:0] best_adc_q;    // best sample seen during the sweep
  logic  [DAC_WIDTH-1:0] best_code_q;   // DAC code that produced best_adc_q
  logic [LOCK_CNT_W-1:0] lock_cnt_q;    // consecutive at-peak iterations
  logic                  locked_q;      // STATUS.LOCKED  (live, not sticky)
  logic                  rail_err_q;    // STATUS.RAIL_ERR  (sticky, W1C)
  logic                  sweep_err_q;   // STATUS.SWEEP_ERR (sticky, W1C)
  logic                  en_q;          // CTRL.EN
  logic            [7:0] dither_q;      // STEP.DITHER as programmed
  logic            [7:0] sweep_q;       // STEP.SWEEP  as programmed
  logic           [15:0] settle_q;      // SETTLE
  logic           [15:0] thresh_q;      // LOCK_CFG.THRESH
  logic           [15:0] minpow_q;      // LOCK_CFG.MINPOW
  logic           [15:0] settle_cnt_q;  // settle-wait counter

  // Not software-visible: en_q delayed one clock, purely to detect the
  // CTRL.EN 0->1 acquisition trigger (spec §3.1) off the registered value.
  logic en_prev_q;

  // ---- Combinational bus decode --------------------------------------------
  logic addr_legal;  // paddr is a mapped register
  logic wr_en;       // legal register write committing this cycle
  logic wr_status;   // legal write targeting STATUS (carries the W1C bits)
  logic en_d;        // next value of en_q (includes a CTRL write this cycle)
  logic en_rise;     // CTRL.EN 0 -> 1 on the registered value

  assign addr_legal = (apb.paddr inside
      {CTRL_OFF, STEP_OFF, SETTLE_OFF, LOCK_CFG_OFF, STATUS_OFF, DAC_OFF, PD_OFF});

  // Register write strobe: only for legal addresses (illegal -> pslverr, no
  // effect). v1.0 has no wait states (pready is always 1 in ACCESS), so this is
  // the completing beat. If a PREADY wait hook is added, gate with && apb.pready
  // so a write commits exactly once, on the completing beat.
  assign wr_en     = apb.psel && apb.penable && apb.pwrite && addr_legal;
  assign wr_status = wr_en && (apb.paddr == STATUS_OFF);

  // EN as it will stand after this cycle's write: used to force S_IDLE on the
  // same edge CTRL.EN drops, so the FSM stops "immediately" (spec §3.1).
  assign en_d    = (wr_en && (apb.paddr == CTRL_OFF)) ? apb.pwdata[0] : en_q;
  assign en_rise = en_q && !en_prev_q;

  // ---- Effective step sizes (spec §2) --------------------------------------
  // A programmed 0 would stall the FSM forever, so both fields clamp to 1 in
  // hardware. The registers still read back the programmed 0.
  logic [STEP_W-1:0] dither_eff;
  logic [STEP_W-1:0] sweep_eff;

  assign dither_eff = (dither_q == '0) ? 8'd1 : dither_q;
  assign sweep_eff  = (sweep_q  == '0) ? 8'd1 : sweep_q;

  // ---- Saturating DAC arithmetic (spec §3.2, §3.4) -------------------------
  // Every sum/difference is evaluated in SUM_W bits, which cannot overflow, and
  // only then clamped to [DAC_MIN, DAC_MAX] -- the DAC never wraps.
  logic [SUM_W-1:0] dac_plus_dither;   // dac_q + dither_eff (exact)
  logic [SUM_W-1:0] dac_plus_sweep;    // dac_q + sweep_eff  (exact)
  logic             hi_sat;            // upper move would exceed DAC_MAX
  logic             lo_sat;            // lower move would fall below DAC_MIN
  logic [DAC_WIDTH-1:0] dac_hi;        // clamped dac_q + dither_eff
  logic [DAC_WIDTH-1:0] dac_lo;        // clamped dac_q - dither_eff
  logic [DAC_WIDTH-1:0] dac_sweep_nxt; // next sweep point, clamped

  assign dac_plus_dither = SUM_W'(dac_q) + SUM_W'(dither_eff);
  assign dac_plus_sweep  = SUM_W'(dac_q) + SUM_W'(sweep_eff);

  assign hi_sat = (dac_plus_dither > SUM_W'(DAC_MAX));
  assign lo_sat = (SUM_W'(dac_q) < SUM_W'(dither_eff));

  assign dac_hi = hi_sat ? DAC_MAX : dac_plus_dither[DAC_WIDTH-1:0];
  assign dac_lo = lo_sat ? DAC_MIN
                         : DAC_WIDTH'(SUM_W'(dac_q) - SUM_W'(dither_eff));

  // ---- Coarse-sweep next values (spec §3.3) --------------------------------
  // best_adc_n / best_code_n are the values best_adc_q / best_code_q are ABOUT
  // to take, i.e. they already include the sample being taken this cycle. The
  // completion test (and the hand-off into the dither loop) MUST use these, not
  // the registered values, or the final sweep point is silently dropped.
  logic                 new_best;      // this sample beats the running best
  logic [ADC_WIDTH-1:0] best_adc_n;
  logic [DAC_WIDTH-1:0] best_code_n;
  logic                 sweep_done;    // no room for another sweep point
  logic                 sweep_pass;    // best (incl. this sample) >= MINPOW

  assign new_best    = (adc_code > best_adc_q);
  assign best_adc_n  = new_best ? adc_code : best_adc_q;
  assign best_code_n = new_best ? dac_q    : best_code_q;

  assign sweep_done    = (dac_plus_sweep > SUM_W'(DAC_MAX));
  assign sweep_pass    = (PWR_W'(best_adc_n) >= PWR_W'(minpow_q));
  assign dac_sweep_nxt = sweep_done ? DAC_MAX : dac_plus_sweep[DAC_WIDTH-1:0];

  // ---- Fine dither decisions (spec §3.4) -----------------------------------
  logic move_up;    // upper probe is brighter by more than THRESH
  logic move_down;  // lower probe is brighter by more than THRESH
  logic at_peak;    // gradient flat AND both probes above MINPOW
  logic [LOCK_CNT_W-1:0] lock_cnt_n;
  logic                  lock_done;

  assign move_up   = (PWR_W'(p_hi_q) > PWR_W'(p_lo_q) + PWR_W'(thresh_q));
  assign move_down = (PWR_W'(p_lo_q) > PWR_W'(p_hi_q) + PWR_W'(thresh_q));
  // The MINPOW terms are what reject a false lock on a dark ring, where both
  // probes read ~0 and the gradient test alone would report "at peak".
  assign at_peak   = !move_up && !move_down &&
                     (PWR_W'(p_hi_q) >= PWR_W'(minpow_q)) &&
                     (PWR_W'(p_lo_q) >= PWR_W'(minpow_q));

  assign lock_cnt_n = !at_peak                            ? '0
                    : (lock_cnt_q == LOCK_CNT_W'(LOCK_N)) ? lock_cnt_q
                                                          : lock_cnt_q + 1'b1;
  assign lock_done  = (lock_cnt_n == LOCK_CNT_W'(LOCK_N));

  // ---- Settle wait (spec §3.2) ---------------------------------------------
  logic in_wait;      // state_q is one of the three *_WAIT states
  logic settle_done;  // settle_q clocks have elapsed in this *_WAIT state

  assign in_wait     = (state_q == S_SWEEP_WAIT) ||
                       (state_q == S_HI_WAIT)    ||
                       (state_q == S_LO_WAIT);
  assign settle_done = (settle_cnt_q >= settle_q);  // SETTLE==0 -> no wait

  // ---- Sticky error sets (spec §3.3, §3.4) ---------------------------------
  // Both are qualified by en_d: an error flag may only be latched by LOOP
  // ACTIVITY, and there is no loop activity on a cycle where CTRL.EN is (being)
  // cleared -- see the "loop actuation gate" note below. Without the en_d term,
  // dropping EN on exactly the cycle the FSM sat in S_UPDATE with a clipped
  // move, or in S_SWEEP_SAMP on a failed final sweep point, would latch a
  // spurious RAIL_ERR / SWEEP_ERR from a loop that is supposed to be stopping.
  logic sweep_set;  // sweep finished with no sample reaching MINPOW
  logic rail_set;   // a dither move was clipped at a DAC rail

  assign sweep_set = en_d && (state_q == S_SWEEP_SAMP) && sweep_done && !sweep_pass;
  assign rail_set  = en_d && (state_q == S_UPDATE) &&
                     ((move_up && hi_sat) || (move_down && lo_sat));

  // ---- Next state (spec §3.2) ----------------------------------------------
  logic [2:0] state_d;

  always_comb begin
    state_d = state_q;  // default on every path -> no inferred latch
    unique case (state_q)
      S_IDLE:       if (en_rise)     state_d = S_SWEEP_WAIT;
      S_SWEEP_WAIT: if (settle_done) state_d = S_SWEEP_SAMP;
      S_SWEEP_SAMP: state_d = !sweep_done ? S_SWEEP_WAIT       // next point
                            : sweep_pass  ? S_HI_WAIT          // resonance found
                                          : S_IDLE;            // SWEEP_ERR
      S_HI_WAIT:    if (settle_done) state_d = S_HI_SAMP;
      S_HI_SAMP:    state_d = S_LO_WAIT;
      S_LO_WAIT:    if (settle_done) state_d = S_LO_SAMP;
      S_LO_SAMP:    state_d = S_UPDATE;
      S_UPDATE:     state_d = S_HI_WAIT;                       // loop for ever
      default:      state_d = S_IDLE;  // unreachable: all 8 codes are legal
    endcase
    // CTRL.EN low -- including a CTRL write clearing it this very cycle --
    // returns the FSM to S_IDLE immediately (spec §3.1).
    if (!en_d) state_d = S_IDLE;
  end

  // ---- Sequential: registers, FSM and datapath (spec §3) -------------------
  // async assert / sync deassert, active-low.
  always_ff @(posedge apb.clk or negedge apb.rst_n) begin
    if (!apb.rst_n) begin
      state_q      <= S_IDLE;
      dac_q        <= '0;
      pd_q         <= '0;
      p_hi_q       <= '0;
      p_lo_q       <= '0;
      best_adc_q   <= '0;
      best_code_q  <= '0;
      lock_cnt_q   <= '0;
      locked_q     <= 1'b0;
      rail_err_q   <= 1'b0;
      sweep_err_q  <= 1'b0;
      en_q         <= 1'b0;
      en_prev_q    <= 1'b0;
      dither_q     <= DITHER_RST;
      sweep_q      <= SWEEP_RST;
      settle_q     <= SETTLE_RST;
      thresh_q     <= THRESH_RST;
      minpow_q     <= MINPOW_RST;
      settle_cnt_q <= '0;
    end else begin
      // --- APB register writes (RO fields and W1C handled separately) -----
      if (wr_en) begin
        unique case (apb.paddr)
          CTRL_OFF:     en_q     <= apb.pwdata[0];
          STEP_OFF:     begin
            dither_q <= apb.pwdata[7:0];
            sweep_q  <= apb.pwdata[15:8];
          end
          SETTLE_OFF:   settle_q <= apb.pwdata[15:0];
          LOCK_CFG_OFF: begin
            thresh_q <= apb.pwdata[15:0];
            minpow_q <= apb.pwdata[31:16];
          end
          STATUS_OFF:   /* W1C : handled in the sticky-flag block below     */ ;
          DAC_OFF:      /* RO  : write silently dropped (no pslverr)        */ ;
          PD_OFF:       /* RO  : write silently dropped (no pslverr)        */ ;
          default:      /* unreachable: wr_en implies addr_legal            */ ;
        endcase
      end

      en_prev_q <= en_q;   // one-cycle history for the CTRL.EN 0->1 edge
      state_q   <= state_d;

      // --- Settle counter: cleared on every state entry (spec §3.2) -------
      if (state_d != state_q) settle_cnt_q <= '0;
      else if (in_wait)       settle_cnt_q <= settle_cnt_q + 16'd1;

      // --- Datapath per state --------------------------------------------
      // LOOP ACTUATION GATE (spec §3.1). Everything that MOVES the loop --
      // dac_q, the sweep bookkeeping and the lock state -- is qualified by
      // en_d, the value CTRL.EN will hold after this cycle's write. When the
      // loop is disabled the FSM is forced to S_IDLE (see state_d above) and
      // dac_q must HOLD its current value: a real heater keeps its bias. It is
      // not enough to clear locked_q/lock_cnt_q afterwards -- without this gate
      // the very edge that drops EN still executes one S_UPDATE move (and could
      // latch RAIL_ERR) or one S_SWEEP_SAMP advance, so the heater lurches by
      // +/-dither_eff exactly as the loop is being switched off.
      //
      // Sample capture (pd_q / p_hi_q / p_lo_q) is deliberately NOT gated: it
      // is passive observation of a free-running ADC (spec §1), it actuates
      // nothing, and PD is specified to hold the most recent sample taken in
      // any sample state (spec §2). p_hi_q/p_lo_q are re-acquired from scratch
      // after a fresh start, so a final capture cannot leak into the next run.
      //
      // Note dac_q is HELD, never cleared: the spec §3.1 clear of dac_q belongs
      // to the EN rising edge (fresh acquisition), not to the falling edge. The
      // sticky error flags likewise survive being disabled.
      unique case (state_q)
        S_IDLE: begin
          // CTRL.EN 0->1 starts a FRESH acquisition (spec §3.1): centre code
          // to 0 and the sweep bookkeeping cleared. Sticky errors survive.
          // state_d == S_SWEEP_WAIT already implies en_d (state_d is forced to
          // S_IDLE whenever en_d is low), so no extra gate is needed here.
          if (state_d == S_SWEEP_WAIT) begin
            dac_q       <= '0;
            best_adc_q  <= '0;
            best_code_q <= '0;
          end
        end

        S_SWEEP_SAMP: begin                      // spec §3.3
          pd_q <= adc_code;                      // 1) latest sample (ungated)
          if (en_d) begin
            best_adc_q  <= best_adc_n;           // 2) running best
            best_code_q <= best_code_n;
            if (sweep_done) begin
              // 3) Completion uses the NEXT best value, so the sample taken in
              //    this very cycle can still win the sweep.
              if (sweep_pass) dac_q <= best_code_n;
            end else begin
              dac_q <= dac_sweep_nxt;            // 4) advance to the next point
            end
          end
        end

        S_HI_SAMP: begin                       // spec §3.2 / §3.4
          p_hi_q <= adc_code;
          pd_q   <= adc_code;
        end

        S_LO_SAMP: begin
          p_lo_q <= adc_code;
          pd_q   <= adc_code;
        end

        S_UPDATE: begin                          // spec §3.4
          if (en_d) begin
            if      (move_up)   dac_q <= dac_hi; // saturating at DAC_MAX
            else if (move_down) dac_q <= dac_lo; // saturating at DAC_MIN
            lock_cnt_q <= lock_cnt_n;
            locked_q   <= lock_done;             // live status, not sticky
          end
        end

        default: /* S_SWEEP_WAIT / S_HI_WAIT / S_LO_WAIT: settle only */ ;
      endcase

      // --- Sticky error flags : W1C, HW set wins (spec §3.5) --------------
      if (sweep_set)                          sweep_err_q <= 1'b1;
      else if (wr_status && apb.pwdata[2])    sweep_err_q <= 1'b0;

      if (rail_set)                           rail_err_q  <= 1'b1;
      else if (wr_status && apb.pwdata[1])    rail_err_q  <= 1'b0;

      // --- CTRL.EN 1->0 : drop the lock state, hold dac_q (spec §3.1) -----
      // The S_UPDATE arm above is gated by en_d, so this is now the ONLY
      // driver of locked_q/lock_cnt_q while the loop is disabled -- there is no
      // longer a same-cycle conflict for assignment order to resolve. dac_q and
      // the sticky flags are intentionally untouched: disabling holds the
      // heater bias and does not clear errors already latched.
      if (!en_d) begin
        locked_q   <= 1'b0;
        lock_cnt_q <= '0;
      end
    end
  end

  // ---- DAC drive : combinational, driven on every path (spec §1, §3.2) -----
  always_comb begin
    dac_code = dac_q;  // default -> no inferred latch
    unique case (state_q)
      S_HI_WAIT, S_HI_SAMP: dac_code = dac_hi;  // +dither, clamped at DAC_MAX
      S_LO_WAIT, S_LO_SAMP: dac_code = dac_lo;  // -dither, clamped at DAC_MIN
      default:              /* S_IDLE / S_SWEEP_* / S_UPDATE: centre code */ ;
    endcase
  end

  // ---- Lock status output (spec §3.4) --------------------------------------
  assign locked = locked_q;

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
          CTRL_OFF:     apb.prdata[0]              = en_q;      // [31:1] rsvd 0
          STEP_OFF:     begin
            apb.prdata[7:0]  = dither_q;
            apb.prdata[15:8] = sweep_q;                         // [31:16] rsvd
          end
          SETTLE_OFF:   apb.prdata[15:0]           = settle_q;  // [31:16] rsvd
          LOCK_CFG_OFF: begin
            apb.prdata[15:0]  = thresh_q;
            apb.prdata[31:16] = minpow_q;
          end
          STATUS_OFF:   begin
            apb.prdata[0] = locked_q;                  // RO,  live
            apb.prdata[1] = rail_err_q;                // W1C, sticky
            apb.prdata[2] = sweep_err_q;               // W1C, sticky
            apb.prdata[3] = (state_q != S_IDLE);       // RO,  ACTIVE
          end
          DAC_OFF:      apb.prdata[DAC_WIDTH-1:0]  = dac_q;     // RO
          PD_OFF:       apb.prdata[ADC_WIDTH-1:0]  = pd_q;      // RO
          default:      /* unreachable: guarded by addr_legal */ ;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
