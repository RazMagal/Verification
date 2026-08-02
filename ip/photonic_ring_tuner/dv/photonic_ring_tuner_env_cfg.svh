// -----------------------------------------------------------------------------
// photonic_ring_tuner_env_cfg.svh : top-level configuration for the tuner env,
//   plus `ring_cfg` -- the randomizable OPTICAL configuration that is the real
//   stimulus of this environment.
//
//   The control loop is CLOSED through the optical model, so there is no
//   pre-computable data stream to randomize: the interesting stimulus is the
//   PHYSICS (where the resonance sits, how sharp it is, how slow the heater is,
//   how bright the laser is). ring_cfg carries the spec-7.4 parameters, the
//   constraint regimes that make each test's outcome deterministic, and the
//   apply() that pushes them onto ring_if.
//
//   NOTE ON `real` AND randomize(): SystemVerilog cannot randomize real
//   variables (they may not appear in constraints), so every knob is a rand int
//   and the reals are DERIVED in post_randomize(). tau is carried as tau_x10 so
//   the time constant has 0.1-cycle resolution.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_ENV_CFG_SVH
`define PHOTONIC_RING_TUNER_ENV_CFG_SVH

// Physical regime selected by a test. Each regime is constrained so that ONE
// property of the loop is violated (or none), which is what makes the negative
// tests self-checking instead of hopeful.
typedef enum {
  RING_MODE_DEFAULT,       // fixed mid-range ring (smoke / register tests)
  RING_MODE_LOCKABLE,      // randomized ring the DEFAULT register set can lock
  RING_MODE_SLOW_THERMAL,  // tau >> programmed SETTLE  -> acquisition must fail
  RING_MODE_DARK,          // laser_on = 0              -> SWEEP_ERR, never locks
  RING_MODE_RAIL           // resonance beyond DAC_MAX  -> RAIL_ERR, never locks
} ring_mode_e;

// Which implementation of the optical physics ring_model should evaluate.
//
//   RING_MODEL_SV       pure SystemVerilog -- THE DEFAULT, and the only backend
//                       that exists unless the build carries +define+RING_DPI.
//   RING_MODEL_DPI      the C model behind common/dpi (photonics_dpi_pkg).
//   RING_MODEL_COMPARE  both, in lockstep on identical inputs, checked against
//                       each other every clock -- see the equivalence test.
//
// The values are pinned to 0/1/2 because ring_if carries the mode as a plain
// `int` (it compiles at $unit, before this package exists, and a `virtual
// ring_if` handle is unparameterized), and ring_model decodes those same three
// integers with its own localparams. Change one, change all three.
typedef enum int {
  RING_MODEL_SV      = 0,
  RING_MODEL_DPI     = 1,
  RING_MODEL_COMPARE = 2
} ring_model_e;

// What the scoreboard must prove about this run (spec 7.5).
typedef enum {
  RING_EXP_NONE,           // no optical outcome asserted (register-only tests)
  RING_EXP_LOCK,           // must acquire: checks 1 (deadline), 2 (accuracy), 3 (stability)
  RING_EXP_LOCK_THEN_LOSS, // must acquire, then LOSE the lock when the ring is
                           // deliberately disturbed, then re-acquire (spec 3.4:
                           // locked_q is a live status, not sticky)
  RING_EXP_NO_LOCK,        // must NOT acquire            : check 4
  RING_EXP_SWEEP_ERR,      // must NOT acquire + SWEEP_ERR: check 4
  RING_EXP_RAIL_ERR        // RAIL_ERR + saturation, no wrap, no lock : check 5
} ring_exp_e;

// -----------------------------------------------------------------------------
class ring_cfg extends uvm_object;

  // ---- geometry : ONE source, photonic_ring_tuner_params.svh ---------------
  // These are the SAME parameters the tb hands the DUT, aliased here only to
  // keep the constraint lines readable. Signed `int` throughout so nothing
  // below is dragged into an unsigned comparison.
  //
  // THE BOUNDS IN THE CONSTRAINTS ARE FRACTIONS OF FULL SCALE, written as the
  // 12-bit codes they were chosen as and rescaled by FS/REF_FS: a 512-code
  // linewidth on a 12-bit DAC is the same physical ring as a 128-code linewidth
  // on a 10-bit one. On the default build DAC_FS == ADC_FS == REF_FS == 4096,
  // so `(k * FS) / REF_FS == k` exactly for every k below -- the rescaling is
  // the identity and the numbers a reader sees are the numbers the solver sees.
  // What does NOT scale is marked where it appears: tau is in CLOCK CYCLES and
  // the noise floor is in absolute ADC LSBs (it is judged against THRESH, a
  // spec-2 register value).
  localparam int DAC_MAX = TUNER_DAC_MAX;   // 4095
  localparam int DAC_FS  = TUNER_DAC_FS;    // 4096 DAC codes, full scale
  localparam int ADC_FS  = TUNER_ADC_FS;    // 4096 ADC LSBs, full scale
  localparam int REF_FS  = TUNER_REF_FS;    // 4096: the scale k is written at

  // Regime selector (NOT rand: the test picks it, the constraints follow).
  ring_mode_e  mode = RING_MODE_LOCKABLE;

  // Which model backend evaluates that regime (NOT rand either: a backend is a
  // property of the RUN, not of the physics). The test sets it; +RING_MODEL
  // overrides it; resolve_model_mode() is the single place that decides.
  ring_model_e model_mode = RING_MODEL_SV;

  // ---- randomized integer knobs -------------------------------------------
  rand int res_code_i;    // resonance position in DAC codes (may exceed dac_max)
  rand int fwhm_code_i;   // linewidth, DAC codes
  rand int tau_x10;       // thermal time constant x 10, clock cycles
  rand int p_peak_i;      // ADC LSBs at perfect alignment
  rand int noise_i;       // uniform ADC noise amplitude, LSBs
  rand bit laser_on;

  // ---- derived reals handed to ring_if (spec 7.4) -------------------------
  real res_code;
  real fwhm_code;
  real tau_cycles;
  real p_peak_lsb;
  real noise_lsb;

  `uvm_object_utils_begin(ring_cfg)
    `uvm_field_enum(ring_mode_e,  mode,       UVM_ALL_ON)
    `uvm_field_enum(ring_model_e, model_mode, UVM_ALL_ON)
    `uvm_field_int (res_code_i,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (fwhm_code_i, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (tau_x10,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (p_peak_i,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (noise_i,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (laser_on,    UVM_ALL_ON)
  `uvm_object_utils_end

  // ---- global sanity bounds ------------------------------------------------
  // The res_code cap is a SOLVER cap, not a physical one: every regime below
  // pins res_code_i inside a much tighter window (the widest is c_rail's
  // DAC_MAX + fwhm/3), so this bound never binds -- it exists only so an
  // unconstrained mode cannot wander.
  constraint c_common {
    res_code_i  inside {[0 : (6000 * DAC_FS) / REF_FS]};   // may exceed the range
    fwhm_code_i inside {[(96 * DAC_FS) / REF_FS : (1024 * DAC_FS) / REF_FS]};
    tau_x10     inside {[10:8000]};     // CLOCK CYCLES x10: no width in this
    // p_peak is a fraction of ADC full scale: FS/4 .. 3*FS/4. It must also stay
    // well above the reset MINPOW -- and that one is a fraction of full scale
    // too (FS/16, see TUNER_MINPOW_RST in photonic_ring_tuner_params.svh), so
    // this bound is 4x..12x MINPOW on EVERY build rather than only on the 12-bit
    // one. Before MINPOW scaled, an ADC_WIDTH of 8 put MINPOW (256) above full
    // scale (255) and no p_peak in any range could have reached it.
    p_peak_i    inside {[(1024 * ADC_FS) / REF_FS : (3072 * ADC_FS) / REF_FS]};
    // ABSOLUTE ADC LSBs, judged vs THRESH -- which is absolute for the same
    // reason (quantization noise is ~0.5 LSB at any width). NOTE the one place
    // this absolute bound meets the now-scaling MINPOW: the DARK regime needs
    // its noise strictly below MINPOW = FS/16, i.e. 8 < FS/16, i.e.
    // ADC_WIDTH >= 8. That is not a new limit -- at ADC_WIDTH = 8 the rescaled
    // DAC bounds below are already collapsing (fwhm's 96-code floor rescales to
    // 6 codes), so this environment's regimes stop being physical there anyway.
    noise_i     inside {[0:8]};
  }

  // ---- fixed mid-range ring for register-only tests ------------------------
  constraint c_default {
    mode == RING_MODE_DEFAULT -> {
      laser_on    == 1'b1;
      res_code_i  == DAC_FS / 2;                  // mid-range: 2048
      fwhm_code_i == DAC_FS / 8;                  //             512
      tau_x10     == 40;
      p_peak_i    == (3000 * ADC_FS) / REF_FS;    //            3000
      noise_i     == 0;
    }
  }

  // ---- LOCKABLE : the DEFAULT register set must acquire on this ring -------
  //  With SETTLE = 32 and tau <= 8 the ring reaches >98% of every commanded step
  //  before the ADC is sampled, so the dither measures a true SPATIAL gradient.
  //  fwhm >= 384 keeps the loop's residual detuning inside the lock threshold:
  //  the loop stops moving once |p_hi - p_lo| <= THRESH (8), and with the
  //  DEFAULT dither of 4 the residual |eps| is at most 2 codes, giving
  //  |p_hi - p_lo| ~= 64*p_peak*|eps|/fwhm^2 <= 2.7 LSB -- comfortably under
  //  THRESH even with the +/-2 LSB noise this mode allows. A narrower ring would
  //  limit-cycle instead of locking, which is a legitimate behaviour but not
  //  what this test is about.
  constraint c_lockable {
    mode == RING_MODE_LOCKABLE -> {
      laser_on    == 1'b1;
      // reachable, and clear of BOTH rails by 384 codes (3/32 of full scale)
      res_code_i  inside {[(384 * DAC_FS) / REF_FS : (3712 * DAC_FS) / REF_FS]};
      fwhm_code_i inside {[(384 * DAC_FS) / REF_FS : (1024 * DAC_FS) / REF_FS]};
      tau_x10     inside {[10:80]};      // tau 1..8 cycles << SETTLE = 32
      p_peak_i    inside {[(1024 * ADC_FS) / REF_FS : (3072 * ADC_FS) / REF_FS]};
      noise_i     inside {[0:2]};        // absolute LSBs, vs THRESH = 8
    }
  }

  // ---- SLOW_THERMAL : the headline bug -------------------------------------
  //  The vseq programs SETTLE = 1 while tau is 400..800 cycles, so the ADC is
  //  sampled long before the ring has thermally settled. During the coarse sweep
  //  the ring temperature lags the DAC ramp by L = rate * tau ~= 2300..3500
  //  codes, so the sweep records its peak at a code roughly L ABOVE the real
  //  resonance. Because L > (dac_max - res_code)/2, the temperature at the end
  //  of the sweep is BELOW that recorded code: the fine loop then heats away
  //  from the resonance, the photodiode goes dark, the MINPOW guard (correctly)
  //  refuses to declare lock, and the DAC drives into the rail. Whatever the
  //  seed, `locked` must never rise. fwhm <= 192 keeps the residual power at the
  //  loop's resting point well under MINPOW -- which is ADC full-scale/16, 0x100
  //  at the default ADC_WIDTH = 12, and stays the SAME FRACTION of full scale on
  //  a narrower converter, so that margin is a ratio and survives a
  //  re-parameterization instead of inverting at 8 bits.
  constraint c_slow_thermal {
    mode == RING_MODE_SLOW_THERMAL -> {
      laser_on    == 1'b1;
      res_code_i  inside {[(128 * DAC_FS) / REF_FS : (640 * DAC_FS) / REF_FS]};
      fwhm_code_i inside {[(96 * DAC_FS) / REF_FS : (192 * DAC_FS) / REF_FS]};
      tau_x10     inside {[4000:8000]};  // tau 400..800 cycles >> SETTLE = 1
      p_peak_i    inside {[(2048 * ADC_FS) / REF_FS : (3072 * ADC_FS) / REF_FS]};
      noise_i     inside {[0:4]};
    }
  }

  // ---- DARK : unplugged fibre / laser off ----------------------------------
  //  trans is forced to 0, so the ADC reads read-noise only (<= 8 LSB, far below
  //  MINPOW = ADC full-scale/16 = 0x100 at ADC_WIDTH 12; the noise floor is
  //  absolute and MINPOW is a fraction, so this margin is the one that narrows
  //  with the converter -- it holds strictly for ADC_WIDTH >= 8, see the note on
  //  noise_i in c_common). The sweep finds nothing above MINPOW anywhere in the
  //  tuning range -> SWEEP_ERR, and the flat "both probes equal" condition must
  //  NOT be mistaken for a peak (spec 3.4).
  constraint c_dark {
    mode == RING_MODE_DARK -> {
      laser_on    == 1'b0;
      res_code_i  inside {[(384 * DAC_FS) / REF_FS : (3712 * DAC_FS) / REF_FS]};
      fwhm_code_i inside {[(384 * DAC_FS) / REF_FS : (1024 * DAC_FS) / REF_FS]};
      tau_x10     inside {[10:80]};
      p_peak_i    inside {[(1024 * ADC_FS) / REF_FS : (3072 * ADC_FS) / REF_FS]};
      noise_i     inside {[0:8]};
    }
  }

  // ---- RAIL : resonance parked just beyond the top of the DAC range --------
  //  delta = res_code - dac_max is held in [fwhm/4 : fwhm/3], i.e. right around
  //  the steepest point of the lineshape (|dP/dd| peaks at |d| = 0.29*fwhm):
  //    * near enough that the last sweep point still sees >= MINPOW light, so
  //      the sweep SUCCEEDS and the fine loop actually engages (a resonance far
  //      outside the range would just give SWEEP_ERR, a different test);
  //    * steep enough that the probe difference AT the rail,
  //      ~4*|dP/dd| ~= 5.2*p_peak/fwhm >= 25 LSB, stays well clear of
  //      THRESH (8) plus the worst-case +/-4 LSB probe noise. The loop therefore
  //      keeps saying "hotter" every single iteration: it saturates, sets
  //      RAIL_ERR, and can NEVER satisfy at_peak (move_up is always true), so
  //      "no lock" is a property of the geometry rather than of luck.
  constraint c_rail {
    mode == RING_MODE_RAIL -> {
      laser_on    == 1'b1;
      fwhm_code_i inside {[(384 * DAC_FS) / REF_FS : (512 * DAC_FS) / REF_FS]};
      p_peak_i    inside {[(2560 * ADC_FS) / REF_FS : (3072 * ADC_FS) / REF_FS]};
      tau_x10     inside {[10:80]};
      noise_i     inside {[0:2]};
      res_code_i >= DAC_MAX + (fwhm_code_i / 4);
      res_code_i <= DAC_MAX + (fwhm_code_i / 3);
    }
  }

  // Same ring as c_default, for the pre-randomize state (and for a test that
  // never randomizes at all): mid-range resonance, FS/8 linewidth, bright.
  function new(string name = "ring_cfg");
    super.new(name);
    res_code_i  = DAC_FS / 2;                  // 2048
    fwhm_code_i = DAC_FS / 8;                  //  512
    tau_x10     = 40;
    p_peak_i    = (3000 * ADC_FS) / REF_FS;    // 3000
    noise_i     = 0;
    laser_on    = 1'b1;
    update_reals();
  endfunction

  // reals are DERIVED, never randomized (SV forbids rand real).
  function void update_reals();
    res_code   = real'(res_code_i);
    fwhm_code  = real'(fwhm_code_i);
    tau_cycles = real'(tau_x10) / 10.0;
    p_peak_lsb = real'(p_peak_i);
    noise_lsb  = real'(noise_i);
  endfunction

  function void post_randomize();
    update_reals();
  endfunction

  // ---- backend selection (spec-independent: this is a DV knob) -------------
  // ONE place decides which model runs, so the fatal below, the coverage
  // sample, the log line and what ring_model actually does can never disagree.
  //
  // Precedence: +RING_MODEL=sv|dpi|compare beats the value the test set, so a
  // whole regression can be re-run against the C model without editing a test.
  // An unrecognised value is a fatal, not a fallback -- silently running the SV
  // model because someone typo'd "compair" would produce a green "equivalence"
  // run that never called C, which is strictly worse than not running at all.
  //
  // Same reasoning for the RING_DPI guard: without the define there is no C to
  // call, and the failure names the missing define instead of pretending.
  function ring_model_e resolve_model_mode();
    string       s;
    ring_model_e m;
    m = model_mode;
    if ($value$plusargs("RING_MODEL=%s", s)) begin
      case (s)
        "sv",      "SV":      m = RING_MODEL_SV;
        "dpi",     "DPI":     m = RING_MODEL_DPI;
        "compare", "COMPARE": m = RING_MODEL_COMPARE;
        default: `uvm_fatal("RING_MODEL", $sformatf(
          "+RING_MODEL=%s is not one of sv|dpi|compare", s))
      endcase
    end
`ifndef RING_DPI
    if (m != RING_MODEL_SV)
      `uvm_fatal("RING_MODEL_NO_DPI", $sformatf(
        {"%s was requested but this build has no DPI layer: it was compiled ",
         "without +define+RING_DPI, so common/dpi/photonics_dpi_pkg.sv declares ",
         "no import \"DPI-C\" and there is no C model to call. Rebuild with ",
         "+define+RING_DPI (see ip/photonic_ring_tuner/sim/Makefile: the *_dpi ",
         "targets) or run with +RING_MODEL=sv."}, m.name()))
`endif
    return m;
  endfunction

  // Push the physics onto the model's interface. Called before reset is
  // released (and again by a vseq that changes the ring mid-test).
  function void apply(virtual ring_if vif);
    if (vif == null) return;
    vif.res_code   = res_code;
    vif.fwhm_code  = fwhm_code;
    vif.tau_cycles = tau_cycles;
    vif.p_peak_lsb = p_peak_lsb;
    vif.noise_lsb  = noise_lsb;
    vif.laser_on   = laser_on;
    // Resolve here and write the resolved value BACK, so everything downstream
    // (the log, the coverage sample, the scoreboard) sees what will actually run
    // rather than what was asked for. ring_model latches it while reset is still
    // asserted, and apply() runs in start_of_simulation_phase, i.e. at time 0,
    // before the first posedge.
    model_mode     = resolve_model_mode();
    vif.model_mode = int'(model_mode);
  endfunction

  // settle_q / tau_cycles -- the ONLY thing the controller can observe about
  // the thermal time constant (spec 7.3), and the axis the coverage cross uses.
  function real settle_ratio(int unsigned settle_q);
    return real'(settle_q) / ((tau_cycles < 1.0) ? 1.0 : tau_cycles);
  endfunction

  function string convert2string();
    return $sformatf(
      "%s: res=%0.1f fwhm=%0.1f tau=%0.1f p_peak=%0.1f noise=%0.1f laser=%0b backend=%s",
      mode.name(), res_code, fwhm_code, tau_cycles, p_peak_lsb, noise_lsb,
      laser_on, model_mode.name());
  endfunction

endclass

// -----------------------------------------------------------------------------
class photonic_ring_tuner_env_cfg extends uvm_object;
  `uvm_object_utils(photonic_ring_tuner_env_cfg)

  // Reused VIP agent configuration (is_active, timeout, coverage_enable).
  apb_config                    m_apb_cfg;

  // RAL model (created + built + locked by the test).
  photonic_ring_tuner_reg_block reg_block;

  // The optical stimulus (randomized by the test).
  ring_cfg                      m_ring_cfg;

  // Env knobs.
  bit          en_scoreboard     = 1'b1;
  bit          en_coverage       = 1'b1;

  // What the scoreboard must prove about this run.
  ring_exp_e   exp_outcome       = RING_EXP_NONE;

  // Safety factor applied to the computed acquisition deadline (check 1). The
  // deadline itself is derived from the PROGRAMMED sweep/settle/dither values,
  // so it tracks whatever the vseq programs.
  int unsigned deadline_margin_x = 2;

  // How long a vseq HOLDS an acquired lock, in clocks, so that check 3
  // (stability) has a window to observe. It is used in two places, which is why
  // it lives here rather than in the vseq:
  //   * the lock vseq waits this many clocks with the loop locked;
  //   * the scoreboard requires the LONGEST observed locked run in a
  //     RING_EXP_LOCK test to be at least stability_window/2 clocks before it
  //     will call check 3 satisfied. Without that, a run that locked for three
  //     clocks and then dropped would "pass" the stability check having proved
  //     nothing about stability.
  int unsigned stability_window  = 2000;

  function new(string name = "photonic_ring_tuner_env_cfg");
    super.new(name);
  endfunction

  // Acquisition deadline in clocks, derived from the PROGRAMMED step/settle
  // values (spec 7.5 check 1) rather than being a magic number:
  //   coarse sweep : ceil((DAC_MAX+1)/sweep_eff) points, each WAIT(settle)+SAMP
  //   fine lock    : enough iterations to walk half a sweep step in dither
  //                  steps, plus LOCK_N at-peak iterations, plus slack; each
  //                  iteration is HI_WAIT+HI_SAMP+LO_WAIT+LO_SAMP+UPDATE
  // Multiplied by deadline_margin_x so it stays a real deadline without being
  // seed-flaky. ONE definition, used by the scoreboard (which enforces it) and
  // by the vseqs (which size their observation windows with it).
  //
  // The sweep length is the DAC's, and LOCK_N is the DUT's, so both come from
  // photonic_ring_tuner_params.svh: a wider heater DAC or a longer lock filter
  // lengthens the deadline instead of quietly failing every acquisition against
  // a 12-bit-sized one. (pts is unchanged arithmetic: floor((DAC_MAX + sw)/sw)
  // == ceil((DAC_MAX + 1)/sw) for every sw >= 1.) The clocks-per-point and
  // clocks-per-iteration terms are FSM structure from spec 3.2, not widths.
  function int unsigned acq_deadline(int unsigned settle_q,
                                     int unsigned sweep_eff,
                                     int unsigned dither_eff);
    int unsigned pts;
    int unsigned cpp;
    int unsigned iters;
    int unsigned cpi;
    int unsigned sw  = (sweep_eff  == 0) ? 1 : sweep_eff;
    int unsigned dit = (dither_eff == 0) ? 1 : dither_eff;
    pts   = (TUNER_DAC_MAX + sw) / sw;
    cpp   = settle_q + 3;
    iters = (sw / dit) + TUNER_LOCK_N + 32;
    cpi   = 2 * (settle_q + 2) + 3;
    return deadline_margin_x * (pts * cpp + iters * cpi) + 500;
  endfunction

endclass

`endif // PHOTONIC_RING_TUNER_ENV_CFG_SVH
