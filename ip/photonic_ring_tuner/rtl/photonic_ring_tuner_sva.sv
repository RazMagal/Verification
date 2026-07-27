// -----------------------------------------------------------------------------
// photonic_ring_tuner_sva : tuner-specific bindable assertions (plain SVA,
//                           no UVM)  -- spec §5
//
//   Bound onto the DUT `photonic_ring_tuner` so it can observe the FSM state,
//   the DAC drive and centre code, the probe/sweep samples, the live status
//   bits and the APB write strobes needed to recognise a legal STATUS
//   write-1-to-clear. Everything referenced exists inside the DUT's scope
//   (spec §4 fixes those names), so no waveform or RAL hooks are required.
//
//   Intended bind (place e.g. in the tb top / a bind file):
//
//     bind photonic_ring_tuner photonic_ring_tuner_sva #(
//         .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
//         .DAC_WIDTH(DAC_WIDTH),   .ADC_WIDTH(ADC_WIDTH),
//         .LOCK_N(LOCK_N)
//     ) u_tuner_sva (
//         .clk(apb.clk), .rst_n(apb.rst_n),
//         .state_q(state_q),
//         .dac_q(dac_q), .dac_code(dac_code), .best_code_q(best_code_q),
//         .p_hi_q(p_hi_q), .p_lo_q(p_lo_q), .pd_q(pd_q),
//         .best_adc_q(best_adc_q), .adc_code(adc_code),
//         .locked(locked), .locked_q(locked_q), .rail_err_q(rail_err_q),
//         .sweep_err_q(sweep_err_q), .en_q(en_q),
//         .thresh_q(thresh_q), .minpow_q(minpow_q), .settle_q(settle_q),
//         .dither_q(dither_q), .sweep_q(sweep_q),
//         .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite),
//         .pready(apb.pready), .paddr(apb.paddr), .pwdata(apb.pwdata)
//     );
//
//   Assumptions: single clock apb.clk, active-low rst_n, checks off in reset,
//   state_q encoded per spec §3.2 (plain [2:0], no enum import needed).
//
//   Two checks deviate from the literal spec §5 wording; both are noted at the
//   property and are deliberate (the literal forms are not true of ANY correct
//   implementation, see p_dac_never_wraps and p_no_lock_without_power).
//
//   The port list above is FIXED by spec §5 and must not grow, so anything the
//   checker needs that is not on it (the settle counter, the sticky-flag set
//   terms, the sweep's combinational next-values) is RECONSTRUCTED locally from
//   the bound signals -- see "Independent reconstruction" below.
//
//   Every property here is meant to be falsifiable: a property that cannot fail
//   for any behaviour is a coverage hole wearing an assertion's name. Where a
//   check is structurally weak against the DUT as written (p_locked_port) the
//   reason is stated at the property, together with the mutation that would
//   make it fire.
// -----------------------------------------------------------------------------
module photonic_ring_tuner_sva #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32,
    parameter int DAC_WIDTH  = 12,
    parameter int ADC_WIDTH  = 12,
    parameter int LOCK_N     = 4
) (
    input logic clk, rst_n,
    input logic [2:0]            state_q,
    input logic [DAC_WIDTH-1:0]  dac_q, dac_code, best_code_q,
    input logic [ADC_WIDTH-1:0]  p_hi_q, p_lo_q, pd_q, best_adc_q, adc_code,
    input logic                  locked, locked_q, rail_err_q, sweep_err_q, en_q,
    input logic [15:0]           thresh_q, minpow_q, settle_q,
    input logic [7:0]            dither_q, sweep_q,
    input logic                  psel, penable, pwrite, pready,
    input logic [ADDR_WIDTH-1:0] paddr,
    input logic [DATA_WIDTH-1:0] pwdata
);

  // ---- Local mirrors of the fixed spec constants ---------------------------
  localparam logic [ADDR_WIDTH-1:0] CTRL_OFF   = 'h00;  // spec §2
  localparam logic [ADDR_WIDTH-1:0] STATUS_OFF = 'h10;  // spec §2

  localparam logic [DAC_WIDTH-1:0] DAC_MAX = {DAC_WIDTH{1'b1}};  // spec §1

  localparam logic [2:0] S_IDLE       = 3'd0;  // spec §3.2
  localparam logic [2:0] S_SWEEP_WAIT = 3'd1;
  localparam logic [2:0] S_SWEEP_SAMP = 3'd2;
  localparam logic [2:0] S_HI_WAIT    = 3'd3;
  localparam logic [2:0] S_HI_SAMP    = 3'd4;
  localparam logic [2:0] S_LO_WAIT    = 3'd5;
  localparam logic [2:0] S_LO_SAMP    = 3'd6;
  localparam logic [2:0] S_UPDATE     = 3'd7;

  localparam logic [1:0] RAIL_BIT  = 2'd1;  // STATUS[1] RAIL_ERR  (W1C)
  localparam logic [1:0] SWEEP_BIT = 2'd2;  // STATUS[2] SWEEP_ERR (W1C)

  // Comparison widths: wide enough that an ADC sample plus THRESH, or a DAC
  // code plus twice a step, cannot overflow the comparison itself.
  localparam int PWR_W     = ((ADC_WIDTH > 16) ? ADC_WIDTH : 16) + 1;
  localparam int DAC_EXT_W = DAC_WIDTH + 9;

  // ---- Derived observables --------------------------------------------------
  // A completing write to STATUS (the only legal way to clear its sticky bits).
  // STATUS is always a mapped address, so this transfer never carries pslverr;
  // pwdata[i]==1 is the per-bit write-1-to-clear request (spec §5).
  wire w1c_xfer = psel && penable && pready && pwrite && (paddr == STATUS_OFF);

  // Effective step sizes: a programmed 0 clamps to 1 in hardware (spec §2).
  wire [DAC_EXT_W-1:0] dither_eff = (dither_q == 8'd0) ? DAC_EXT_W'(1)
                                                       : DAC_EXT_W'(dither_q);
  wire [DAC_EXT_W-1:0] sweep_eff  = (sweep_q  == 8'd0) ? DAC_EXT_W'(1)
                                                       : DAC_EXT_W'(sweep_q);

  // Largest legal single-cycle change of dac_code. Inside the dither loop the
  // drive walks (centre-dither) -> centre -> (centre'+dither) where centre' may
  // itself have moved by dither, i.e. up to 2*dither_eff; inside the sweep it
  // steps by sweep_eff. (Spec §5.2 says max(dither,sweep); that under-counts
  // the S_UPDATE -> S_HI_WAIT step by a factor of two.)
  wire [DAC_EXT_W-1:0] max_step = ((dither_eff << 1) > sweep_eff)
                                  ? (dither_eff << 1) : sweep_eff;

  wire [DAC_EXT_W-1:0] dac_ext  = DAC_EXT_W'(dac_code);

  // PWR_W is one bit wider than the widest of {ADC sample, 16-bit field}, so
  // p_lo + THRESH cannot overflow the comparison (mirrors the DUT).
  wire [PWR_W-1:0] phi_w    = PWR_W'(p_hi_q);
  wire [PWR_W-1:0] plo_w    = PWR_W'(p_lo_q);
  wire [PWR_W-1:0] pd_w     = PWR_W'(pd_q);
  wire [PWR_W-1:0] minpow_w = PWR_W'(minpow_q);
  wire [PWR_W-1:0] thresh_w = PWR_W'(thresh_q);

  wire in_wait = (state_q == S_SWEEP_WAIT) || (state_q == S_HI_WAIT) ||
                 (state_q == S_LO_WAIT);
  wire in_samp = (state_q == S_SWEEP_SAMP) || (state_q == S_HI_SAMP) ||
                 (state_q == S_LO_SAMP);

  // ---- Independent reconstruction of the DUT's internal decisions ----------
  // The bind port list is fixed by spec §5, so the DUT's rail_set / sweep_set /
  // best_code_n terms are not directly observable. They are rebuilt here from
  // the signals that ARE bound, using the spec §3.3/§3.4 formulae -- not copied
  // from the RTL expressions -- so that a mistake in the DUT's version shows up
  // as a mismatch. The comparison widths mirror the DUT's so that a rebuilt
  // term differs from the DUT's only if the DUT's behaviour is wrong.
  //
  // en_d is the value CTRL.EN takes after this cycle's write: the loop is
  // disabled (and therefore may not move dac_q or latch an error, spec §3.1)
  // on the very edge a CTRL write clears EN, one clock before en_q shows it.
  wire ctrl_wr = psel && penable && pready && pwrite && (paddr == CTRL_OFF);
  wire en_d    = ctrl_wr ? pwdata[0] : en_q;

  // Fine-loop decisions (spec §3.4).
  wire move_up_obs   = (phi_w > plo_w + thresh_w);
  wire move_down_obs = (plo_w > phi_w + thresh_w);
  wire hi_sat_obs    = ((DAC_EXT_W'(dac_q) + dither_eff) > DAC_EXT_W'(DAC_MAX));
  wire lo_sat_obs    = (DAC_EXT_W'(dac_q) < dither_eff);

  // RAIL_ERR is set by an S_UPDATE whose move clips at a rail (spec §3.4).
  wire rail_set_obs  = en_d && (state_q == S_UPDATE) &&
                       ((move_up_obs && hi_sat_obs) || (move_down_obs && lo_sat_obs));

  // Coarse-sweep decisions (spec §3.3). best_*_n are the NEXT values, i.e. they
  // include the sample being taken this cycle -- the completion test and the
  // hand-off into the fine loop are both specified against these, not against
  // the registered best_adc_q / best_code_q.
  wire                 new_best_obs    = (adc_code > best_adc_q);
  wire [ADC_WIDTH-1:0] best_adc_n_obs  = new_best_obs ? adc_code : best_adc_q;
  wire [DAC_WIDTH-1:0] best_code_n_obs = new_best_obs ? dac_q    : best_code_q;
  wire sweep_done_obs = ((DAC_EXT_W'(dac_q) + sweep_eff) > DAC_EXT_W'(DAC_MAX));
  wire sweep_pass_obs = (PWR_W'(best_adc_n_obs) >= minpow_w);

  // SWEEP_ERR is set by a completing sweep whose best sample misses MINPOW.
  wire sweep_set_obs  = en_d && (state_q == S_SWEEP_SAMP) &&
                        sweep_done_obs && !sweep_pass_obs;

  // ---- Checker-local state-dwell counter (spec §5.7) -----------------------
  // settle_cnt_q is not on the bind port list, so the checker rebuilds the
  // same quantity independently: in_state_cnt is 0 in the first clock spent in
  // a state and increments thereafter, exactly like the DUT's settle counter.
  logic [2:0]  state_prev_q;
  logic [15:0] dwell_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_prev_q <= S_IDLE;
      dwell_q      <= '0;
    end else begin
      state_prev_q <= state_q;
      if (state_q != state_prev_q)   dwell_q <= 16'd1;   // entered this cycle
      else if (dwell_q != 16'hFFFF)  dwell_q <= dwell_q + 16'd1;
    end
  end

  wire [15:0] in_state_cnt = (state_q != state_prev_q) ? 16'd0 : dwell_q;

  // 1) The locked port is exactly the locked_q status bit (spec §5.1, §3.4).
  //
  //    `locked == locked_q` ALONE is a tautology against the DUT as written
  //    (`assign locked = locked_q` in the same scope drives both bind
  //    arguments from one net), so it cannot fail for any value of any signal
  //    and buys no coverage. It is kept only because it does still catch the
  //    port being re-timed -- registering the port, or driving it from
  //    lock_done instead of locked_q, makes the two bind arguments distinct
  //    nets -- and it is paired here with the behavioural term that gives §5.1
  //    real content: spec §3.1 requires CTRL.EN low to CLEAR locked_q, so
  //    `locked` must read 0 whenever the loop is disabled. That term is
  //    falsifiable: delete the DUT's `if (!en_d) locked_q <= 1'b0` and a run
  //    that drops EN while locked fails on the next clock.
  //
  //    (en_q, not en_d: en_q is the registered value, and locked_q is cleared
  //    in the same clock as en_q updates, so the two are aligned here.)
  property p_locked_port;
    @(posedge clk) disable iff (!rst_n)
      (locked == locked_q) && (en_q || !locked_q);
  endproperty
  a_locked_port : assert property (p_locked_port)
      else $error("TUNER: locked != locked_q, or locked_q held with CTRL.EN low");

  //    locked_q is fine-loop state: it may only change on the clock following
  //    an S_UPDATE evaluation, or as the disable clear above. Anything else --
  //    a lock declared mid-sweep, a stray clear from a WAIT state -- is a bug.
  property p_locked_only_from_update;
    @(posedge clk) disable iff (!rst_n)
      $changed(locked_q) |-> (($past(state_q) == S_UPDATE) || !en_q);
  endproperty
  a_locked_only_from_update : assert property (p_locked_only_from_update)
      else $error("TUNER: locked_q changed outside an S_UPDATE / disable clear");

  // 2) The DAC drive never wraps (spec §5.2). A rail wraparound (DAC_MAX -> 0
  //    or 0 -> DAC_MAX) shows up as a single-cycle jump far larger than a step.
  //    Two transitions legitimately move the drive by an arbitrary amount and
  //    are excluded: leaving S_IDLE (a fresh acquisition forces dac_q to 0,
  //    spec §3.1) and the sweep hand-off S_SWEEP_SAMP -> S_HI_WAIT (dac_q is
  //    loaded with best_code, spec §3.3). The leading ##1 keeps $past legal.
  //    The bound is the larger of the old and new max_step so that a STEP write
  //    landing on this very edge (legal at any time) is not flagged.
  property p_dac_never_wraps;
    @(posedge clk) disable iff (!rst_n)
      ##1 (($past(state_q) != S_IDLE) &&
           !(($past(state_q) == S_SWEEP_SAMP) && (state_q == S_HI_WAIT)))
          |-> ((dac_ext >= $past(dac_ext)) ? (dac_ext - $past(dac_ext))
                                           : ($past(dac_ext) - dac_ext))
              <= ((max_step > $past(max_step)) ? max_step : $past(max_step));
  endproperty
  a_dac_never_wraps : assert property (p_dac_never_wraps)
      else $error("TUNER: dac_code jumped by more than one step (rail wrap?)");

  // 3) No lock without power (spec §5.3, §3.4) -- the false-lock guard.
  //    Checked at the two structurally meaningful instants instead of the
  //    literal "locked_q is never high while pd_q < minpow_q": pd_q, p_hi_q and
  //    p_lo_q are re-sampled one dither iteration BEFORE locked_q can respond,
  //    so the literal form fires on every legitimate lock loss (which spec §5
  //    itself asks to cover). Instead:
  //      a) at the instant lock is declared, every sample the deciding S_UPDATE
  //         evaluation had in hand was >= the MINPOW then in force ($past, so a
  //         LOCK_CFG write on the same edge cannot cause a false failure);
  //      b) an S_UPDATE evaluation with either probe below MINPOW must drop
  //         locked_q on the very next clock -- a dark ring cannot stay locked.
  property p_no_lock_without_power;
    @(posedge clk) disable iff (!rst_n)
      $rose(locked_q) |-> ($past(phi_w) >= $past(minpow_w)) &&
                          ($past(plo_w) >= $past(minpow_w)) &&
                          ($past(pd_w)  >= $past(minpow_w));
  endproperty
  a_no_lock_without_power : assert property (p_no_lock_without_power)
      else $error("TUNER: lock declared with a probe below MINPOW (false lock)");

  property p_no_lock_when_dark;
    @(posedge clk) disable iff (!rst_n)
      ((state_q == S_UPDATE) && ((phi_w < minpow_w) || (plo_w < minpow_w)))
          |=> !locked_q;
  endproperty
  a_no_lock_when_dark : assert property (p_no_lock_when_dark)
      else $error("TUNER: locked_q held through a below-MINPOW update");

  // 4) Sticky error flags: set by HW, cleared only by a W1C (spec §5.4, §3.5).
  property p_rail_sticky;
    @(posedge clk) disable iff (!rst_n)
      (rail_err_q && !(w1c_xfer && pwdata[RAIL_BIT])) |=> rail_err_q;
  endproperty
  a_rail_sticky : assert property (p_rail_sticky)
      else $error("TUNER: RAIL_ERR self-cleared without a W1C");

  property p_sweep_err_sticky;
    @(posedge clk) disable iff (!rst_n)
      (sweep_err_q && !(w1c_xfer && pwdata[SWEEP_BIT])) |=> sweep_err_q;
  endproperty
  a_sweep_err_sticky : assert property (p_sweep_err_sticky)
      else $error("TUNER: SWEEP_ERR self-cleared without a W1C");

  // 4b) HW-SET-WINS (spec §3.5): if a hardware set and a W1C to the same bit
  //     land on the same clock, the bit stays set. The two p_*_sticky
  //     properties above cannot check this -- their antecedent EXCLUDES the
  //     W1C, so they go vacuous in precisely the race cycle, which is why the
  //     race was previously only covered and never asserted. These two close
  //     that hole; each is the same-clock race spelled out directly.
  //
  //     Falsifiability: swap the DUT's priority to W1C-first (make the clear
  //     the `if` and the set the `else if`) and both fire on the first race,
  //     while every other check in this file still passes. The paired
  //     c_w1c_race_*_hw covers below prove the antecedent is actually reached,
  //     i.e. that these are not silently vacuous.
  //
  //     rail_set_obs / sweep_set_obs carry an en_d term, but w1c_xfer already
  //     pins paddr to STATUS, so no CTRL write can be in flight in the same
  //     ACCESS phase and en_d == en_q here -- the reconstruction is exact.
  property p_rail_hw_set_wins;
    @(posedge clk) disable iff (!rst_n)
      (rail_set_obs && w1c_xfer && pwdata[RAIL_BIT]) |=> rail_err_q;
  endproperty
  a_rail_hw_set_wins : assert property (p_rail_hw_set_wins)
      else $error("TUNER: W1C beat a same-clock HW set of RAIL_ERR");

  property p_sweep_err_hw_set_wins;
    @(posedge clk) disable iff (!rst_n)
      (sweep_set_obs && w1c_xfer && pwdata[SWEEP_BIT]) |=> sweep_err_q;
  endproperty
  a_sweep_err_hw_set_wins : assert property (p_sweep_err_hw_set_wins)
      else $error("TUNER: W1C beat a same-clock HW set of SWEEP_ERR");

  // 5) Disabled => idle on the next clock (spec §5.5, §3.1).
  property p_idle_when_disabled;
    @(posedge clk) disable iff (!rst_n)
      !en_q |=> (state_q == S_IDLE);
  endproperty
  a_idle_when_disabled : assert property (p_idle_when_disabled)
      else $error("TUNER: FSM left S_IDLE while CTRL.EN was low");

  // 6) Probe polarity (spec §5.6, §3.2): the high probe is never below the
  //    centre code and the low probe never above it. A swap here inverts the
  //    gradient and turns the loop into positive feedback.
  property p_probe_hi_ge_centre;
    @(posedge clk) disable iff (!rst_n)
      ((state_q == S_HI_WAIT) || (state_q == S_HI_SAMP)) |-> (dac_code >= dac_q);
  endproperty
  a_probe_hi_ge_centre : assert property (p_probe_hi_ge_centre)
      else $error("TUNER: S_HI_* drove dac_code below the centre code");

  property p_probe_lo_le_centre;
    @(posedge clk) disable iff (!rst_n)
      ((state_q == S_LO_WAIT) || (state_q == S_LO_SAMP)) |-> (dac_code <= dac_q);
  endproperty
  a_probe_lo_le_centre : assert property (p_probe_lo_le_centre)
      else $error("TUNER: S_LO_* drove dac_code above the centre code");

  // 7) Settle time honoured (spec §5.7, §3.2): a *_WAIT state is never left
  //    before settle_q clocks have elapsed in it. Dropping CTRL.EN aborts to
  //    S_IDLE at any time (spec §3.1) and is the one permitted early exit.
  property p_settle_honoured;
    @(posedge clk) disable iff (!rst_n)
      (in_wait && (in_state_cnt < settle_q))
          |=> ($stable(state_q) || (state_q == S_IDLE));
  endproperty
  a_settle_honoured : assert property (p_settle_honoured)
      else $error("TUNER: left a *_WAIT state before SETTLE clocks elapsed");

  // ---- Extra structural checks (beyond spec §5, same signals) --------------
  // PD mirrors the most recent ADC sample in every sample state (spec §2).
  property p_pd_captures_adc;
    @(posedge clk) disable iff (!rst_n)
      in_samp |=> (pd_q == $past(adc_code));
  endproperty
  a_pd_captures_adc : assert property (p_pd_captures_adc)
      else $error("TUNER: pd_q did not capture adc_code in a sample state");

  // The centre code always moves TOWARD the brighter probe, and does not move
  // at all inside the THRESH dead-band (spec §3.4). Together with the probe
  // polarity check this is what rules out an inverted (positive-feedback) loop.
  property p_move_toward_bright;
    @(posedge clk) disable iff (!rst_n)
      (state_q == S_UPDATE) |=>
        (($past(phi_w) > $past(plo_w) + $past(thresh_w)) ? (dac_q >= $past(dac_q))
       : ($past(plo_w) > $past(phi_w) + $past(thresh_w)) ? (dac_q <= $past(dac_q))
                                                         : $stable(dac_q));
  endproperty
  a_move_toward_bright : assert property (p_move_toward_bright)
      else $error("TUNER: centre code moved away from the brighter probe");

  // The running sweep best never decreases while the sweep is in progress, and
  // best_code_q is always a code the sweep has already visited (spec §3.3).
  property p_best_monotonic;
    @(posedge clk) disable iff (!rst_n)
      (state_q == S_SWEEP_SAMP) |=> (best_adc_q >= $past(best_adc_q));
  endproperty
  a_best_monotonic : assert property (p_best_monotonic)
      else $error("TUNER: best_adc_q decreased during the sweep");

  // 12) The code the sweep HANDS OFF to the fine loop (spec §5.12, §3.3).
  //
  //     This must constrain the hand-off value itself. The previous form --
  //     `best_code_q <= dac_q` while in S_SWEEP_*` -- could not: it never
  //     looks at the S_SWEEP_SAMP -> S_HI_WAIT edge at all, so the exact
  //     off-by-one it is documented to catch (loading dac_q from the
  //     REGISTERED best_code_q instead of the combinational next value, which
  //     silently throws away the final sweep point) leaves it passing on every
  //     cycle. That within-sweep bound is kept below, demoted to what it
  //     really is: a monotonicity check, not a hand-off check.
  //
  //     The antecedent `S_SWEEP_SAMP ##1 S_HI_WAIT` is exactly the hand-off:
  //     S_SWEEP_SAMP's only other successors are S_SWEEP_WAIT (sweep
  //     continues) and S_IDLE (SWEEP_ERR, or CTRL.EN dropped). The consequent
  //     is a tight EQUALITY against the checker's own best_code_n_obs, so any
  //     deviation -- not merely a too-large one -- fails.
  property p_best_code_visited;
    @(posedge clk) disable iff (!rst_n)
      ((state_q == S_SWEEP_SAMP) ##1 (state_q == S_HI_WAIT))
          |-> (dac_q == $past(best_code_n_obs));
  endproperty
  a_best_code_visited : assert property (p_best_code_visited)
      else $error("TUNER: sweep handed the fine loop a code it never sampled best");

  //     Secondary: within a sweep the running best is never a code the sweep
  //     has not reached yet.
  property p_best_code_not_ahead;
    @(posedge clk) disable iff (!rst_n)
      ((state_q == S_SWEEP_WAIT) || (state_q == S_SWEEP_SAMP))
          |-> (best_code_q <= dac_q);
  endproperty
  a_best_code_not_ahead : assert property (p_best_code_not_ahead)
      else $error("TUNER: best_code_q is ahead of the current sweep point");

  // ---- Coverage (spec §5) --------------------------------------------------
  // The loop actually acquiring lock.
  c_locked_rise    : cover property (@(posedge clk) disable iff (!rst_n)
                        $rose(locked_q));
  // Both error flags actually being reached.
  c_rail_err_rise  : cover property (@(posedge clk) disable iff (!rst_n)
                        $rose(rail_err_q));
  c_sweep_err_rise : cover property (@(posedge clk) disable iff (!rst_n)
                        $rose(sweep_err_q));
  // A lock that is lost after having been acquired (drift / laser loss).
  c_lock_lost      : cover property (@(posedge clk) disable iff (!rst_n)
                        $rose(locked_q) ##[1:$] $fell(locked_q));
  // The W1C-vs-HW-set race, observed from the software side: a W1C attempt on
  // an already-set bit that leaves it still set next cycle. Absent a same-clock
  // hardware set the W1C would have cleared it, so a hit here IS the race
  // (spec §3.5). Both flags, so SWEEP_ERR is measured like RAIL_ERR.
  c_w1c_race_rail  : cover property (@(posedge clk) disable iff (!rst_n)
                        (w1c_xfer && pwdata[RAIL_BIT] && rail_err_q)
                        ##1 rail_err_q);
  c_w1c_race_sweep : cover property (@(posedge clk) disable iff (!rst_n)
                        (w1c_xfer && pwdata[SWEEP_BIT] && sweep_err_q)
                        ##1 sweep_err_q);

  // The same race seen from the hardware side, i.e. the exact antecedent of
  // a_rail_hw_set_wins / a_sweep_err_hw_set_wins. These also catch the case the
  // covers above cannot see -- the flag being set for the FIRST time on the
  // same clock as the W1C -- and, being the assertions' own antecedents, they
  // are what proves those assertions are not vacuously passing.
  c_w1c_race_rail_hw  : cover property (@(posedge clk) disable iff (!rst_n)
                          rail_set_obs && w1c_xfer && pwdata[RAIL_BIT]);
  c_w1c_race_sweep_hw : cover property (@(posedge clk) disable iff (!rst_n)
                          sweep_set_obs && w1c_xfer && pwdata[SWEEP_BIT]);

endmodule
