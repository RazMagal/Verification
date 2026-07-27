// -----------------------------------------------------------------------------
// photonic_ring_tuner_scoreboard.svh : optical-loop scoreboard (spec 7.5).
//
//   There is no cycle-exact reference model here, and that is deliberate. The
//   DUT's input is a function of its own output through a CONTINUOUS-VALUED
//   model, so a bit-exact predictor would have to re-implement the ring, the
//   photodiode and the ADC rounding and would then only be testing itself. The
//   meaningful checks are PROPERTIES of the closed loop, checked against the
//   model's internal truth (detune_code):
//
//     1) ACQUISITION - with the laser on and a reachable resonance, `locked`
//                      rises within a deadline DERIVED from the programmed
//                      SWEEP / SETTLE / DITHER values (so it tracks whatever
//                      the vseq programs, rather than being a magic number).
//     2) ACCURACY    - while locked, |detune_code| <= fwhm_code/2. The loop must
//                      land ON the resonance, not merely stop moving. This is
//                      the check that cannot be made from the DUT pins alone.
//     3) STABILITY   - while locked, dac_q stays within +/-2*dither_eff of its
//                      value at lock: no limit cycle, no slow walk-off. dac_q
//                      itself is internal, but in the fine phase dac_code takes
//                      exactly {dac_q-dither_eff, dac_q, dac_q+dither_eff}, so
//                      the equivalent pin-observable statement is
//                      span(dac_code) <= 4*dither_eff (dac_q wander) +
//                      2*dither_eff (probe excursion) = 6*dither_eff.
//     4) NO FALSE LOCK - with the laser off, `locked` must NEVER rise and
//                      SWEEP_ERR must be set instead (spec 3.4: both probes read
//                      ~0 on a dark ring, so a gradient-only lock rule would
//                      declare a false lock; the MINPOW term is what stops it).
//     5) RAIL        - with the resonance outside the DAC range, RAIL_ERR is set
//                      and the DAC saturates WITHOUT WRAPPING.
//
//   LIVENESS (why the negative verdicts are not vacuous)
//   ---------------------------------------------------
//   Checks 4 and 5 are NEGATIVE: "`locked` never rose". A purely negative
//   verdict is passed trivially by a DUT that does nothing at all -- `locked`
//   tied low, an FSM that never leaves S_IDLE, a dead photodiode, a dac_code
//   tied to 0 -- so on its own it proves nothing. Every non-NONE verdict
//   therefore ALSO demands POSITIVE evidence that the loop ran (check_loop_ran):
//
//     * an acquisition was actually started      (CTRL.EN 0->1 seen on the bus);
//     * STATUS.ACTIVE was read HIGH              (the FSM left S_IDLE);
//     * dac_code visited a SPREAD of codes       (the coarse sweep really ramped
//       at least half the DAC range: dac_code is not tied off and the sweep is
//       not stuck);
//     * on a LIT ring, the model delivered light above MINPOW and the DUT's own
//       PD register was observed NON-ZERO        (the photodiode path into the
//       DUT is alive and it really was sampling).
//
//   The mirror-image vacuity applies to the POSITIVE verdict too: check 3
//   (stability) says nothing if the lock only ever held for a handful of clocks,
//   so RING_EXP_LOCK also requires the longest locked run to reach
//   env_cfg.stability_window/2.
//
//   Inputs:
//     apb_fifo : the APB monitor stream (uvm_tlm_analysis_fifo, house style) -
//                used to shadow the PROGRAMMED register values, to timestamp the
//                CTRL.EN 0->1 that starts an acquisition, and to observe the
//                sticky STATUS error flags (which are only visible over the bus).
//     ring_vif : the optical interface, sampled once per posedge through mon_cb
//                so the digital signals and the model's reals are one coherent
//                preponed snapshot.
//
//   Output:
//     acq_ap   : one acquisition-result record per run, for functional coverage.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_SCOREBOARD_SVH
`define PHOTONIC_RING_TUNER_SCOREBOARD_SVH

// Acquisition-result record published for coverage (spec 7.6).
class photonic_ring_tuner_acq_item extends uvm_sequence_item;
  bit          locked_seen;    // `locked` rose at least once
  bit          lost_lock;      // `locked` fell again while still enabled
  bit          rail_err;       // STATUS.RAIL_ERR observed set
  bit          sweep_err;      // STATUS.SWEEP_ERR observed set
  bit          laser_on;
  bit          init_detune_pos; // sign of (temp - res_code) when EN rose
  int unsigned settle_prog;    // SETTLE as programmed for this acquisition
  int unsigned dither_eff;     // effective dither step (0 -> 1)
  int unsigned acq_cycles;     // EN rise -> locked, 0 if never acquired
  real         tau_cycles;
  real         ratio;          // settle_prog / tau_cycles  (spec 7.3)
  real         res_code;
  real         fwhm_code;

  `uvm_object_utils_begin(photonic_ring_tuner_acq_item)
    `uvm_field_int(locked_seen, UVM_ALL_ON)
    `uvm_field_int(lost_lock,   UVM_ALL_ON)
    `uvm_field_int(rail_err,    UVM_ALL_ON)
    `uvm_field_int(sweep_err,   UVM_ALL_ON)
    `uvm_field_int(laser_on,        UVM_ALL_ON)
    `uvm_field_int(init_detune_pos, UVM_ALL_ON)
    `uvm_field_int(settle_prog, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(dither_eff,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(acq_cycles,  UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "photonic_ring_tuner_acq_item");
    super.new(name);
  endfunction
endclass

// -----------------------------------------------------------------------------
class photonic_ring_tuner_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(photonic_ring_tuner_scoreboard)

  uvm_tlm_analysis_fifo #(apb_seq_item)              apb_fifo;
  uvm_analysis_port #(photonic_ring_tuner_acq_item)  acq_ap;

  virtual ring_if                                    ring_vif;
  photonic_ring_tuner_env_cfg                        m_cfg;

  // register byte offsets (spec 2)
  localparam bit [7:0] CTRL_OFF     = 8'h00;
  localparam bit [7:0] STEP_OFF     = 8'h04;
  localparam bit [7:0] SETTLE_OFF   = 8'h08;
  localparam bit [7:0] LOCK_CFG_OFF = 8'h0C;
  localparam bit [7:0] STATUS_OFF   = 8'h10;
  localparam bit [7:0] DAC_OFF      = 8'h14;
  localparam bit [7:0] PD_OFF       = 8'h18;

  // DUT geometry (matches the tb's parameterization).
  localparam int unsigned DAC_MAX = 4095;

  // ---- shadow of the PROGRAMMED register values (spec 2 reset values) ----
  bit [7:0]    dither_prog = 8'h04;
  bit [7:0]    sweep_prog  = 8'h20;
  bit [15:0]   settle_prog = 16'h0020;
  bit [15:0]   thresh_prog = 16'h0008;
  bit [15:0]   minpow_prog = 16'h0100;
  bit          en_prog     = 1'b0;

  // ---- observed STATUS flags (only visible over the bus) ----
  bit          saw_rail_err;
  bit          saw_sweep_err;
  bit          saw_status_locked;

  // ---- LIVENESS evidence : proof that the loop actually RAN ----------------
  // Without these, every negative verdict below is passed by a DUT that does
  // nothing at all (see the header). All of them are POSITIVE observations.
  bit          saw_status_active;   // STATUS.ACTIVE read 1 -> FSM left S_IDLE
  int unsigned max_pd_read;         // largest PD (pd_q) value read over the bus
  int unsigned max_adc_seen;        // largest adc_code the model ever presented
  int unsigned dac_run_lo;          // dac_code extremes seen since the first
  int unsigned dac_run_hi;          //   CTRL.EN 0->1 (the sweep's spread)
  bit          dac_run_valid;

  // ---- cycle-domain state ----
  int unsigned cyc;
  int unsigned en_rise_cyc;
  int unsigned last_ctrl_cyc;
  int unsigned deadline_cyc;
  bit          acq_armed;
  bit          acq_done;
  int unsigned acq_cycles;
  int unsigned n_en_rise;
  int unsigned n_apb;

  // lock observation
  bit          lk_prev;
  bit          locked_seen;
  int unsigned n_lock_rise;
  int unsigned locked_cycles;
  int unsigned max_locked_run;      // longest single locked episode, in clocks
  int unsigned dac_at_lock;
  int unsigned dac_lo_seen;
  int unsigned dac_hi_seen;
  bit          lost_lock_any;
  bit          lost_lock_while_en;
  real         last_det;              // live detuning, for the EN-rise snapshot
  real         det_at_en;             // detuning when the acquisition started

  // dac observation
  int unsigned dac_prev;
  bit          dac_prev_valid;
  bit          dac_hit_max;
  int unsigned n_big_jumps;

  // failure latches (each check reports ONCE, then counts)
  bit          accuracy_fail;
  int unsigned accuracy_hits;
  bit          stability_fail;
  int unsigned stability_hits;
  bit          rail_wrap_fail;
  bit          deadline_fail;

  function new(string name = "photonic_ring_tuner_scoreboard",
               uvm_component parent = null);
    super.new(name, parent);
    acq_ap = new("acq_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    apb_fifo = new("apb_fifo", this);
    if (!uvm_config_db#(virtual ring_if)::get(this, "", "ring_vif", ring_vif))
      `uvm_fatal("SCB_NOVIF", "virtual ring_if 'ring_vif' not set for scoreboard")
    if (!uvm_config_db#(photonic_ring_tuner_env_cfg)::get(this, "", "env_cfg", m_cfg))
      `uvm_fatal("SCB_NOCFG", "photonic_ring_tuner_env_cfg 'env_cfg' not set")
  endfunction

  // ---- helpers -------------------------------------------------------------
  function int unsigned dither_eff();
    return (dither_prog == 0) ? 1 : int'(dither_prog);
  endfunction

  function int unsigned sweep_eff();
    return (sweep_prog == 0) ? 1 : int'(sweep_prog);
  endfunction

  function real rabs(real x);
    return (x < 0.0) ? -x : x;
  endfunction

  // Null-safe description of the ring under test (for messages).
  function string ring_str();
    return (m_cfg.m_ring_cfg != null) ? m_cfg.m_ring_cfg.convert2string() : "n/a";
  endfunction

  // Was the laser on for this run? (the DARK regime has no light to find, so the
  // photodiode-side liveness evidence does not apply there).
  function bit ring_is_lit();
    return (m_cfg.m_ring_cfg == null) ? 1'b1 : m_cfg.m_ring_cfg.laser_on;
  endfunction

  // Does THIS test document an optical lock verdict (spec 7.5 checks 2 and 3)?
  function bit lock_is_expected();
    return (m_cfg.exp_outcome == RING_EXP_LOCK) ||
           (m_cfg.exp_outcome == RING_EXP_LOCK_THEN_LOSS);
  endfunction

  // Acquisition deadline in clocks (spec 7.5 check 1). The formula lives in
  // photonic_ring_tuner_env_cfg so the vseqs size their observation windows
  // from exactly the same definition the scoreboard enforces.
  function int unsigned acq_deadline();
    return m_cfg.acq_deadline(int'(settle_prog), sweep_eff(), dither_eff());
  endfunction

  // ---- run -----------------------------------------------------------------
  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    fork
      snoop_apb();
      watch_ring();
    join
  endtask

  // Shadow the programmed configuration, timestamp CTRL.EN 0->1, and latch the
  // sticky STATUS error flags as the vseq polls them.
  task snoop_apb();
    apb_seq_item t;
    bit          new_en;
    forever begin
      apb_fifo.get(t);
      n_apb++;
      if (t.slverr) continue;                    // illegal access: no register effect
      if (t.dir == APB_WRITE) begin
        case (t.addr)
          CTRL_OFF: begin
            new_en        = t.wdata[0];
            last_ctrl_cyc = cyc;
            if (new_en && !en_prog) begin
              n_en_rise++;
              en_rise_cyc  = cyc;
              deadline_cyc = cyc + acq_deadline();
              acq_armed    = 1'b1;
              acq_done     = 1'b0;      // every acquisition gets its own deadline
              deadline_fail= 1'b0;
              det_at_en    = last_det;   // initial detuning sign, for coverage
              `uvm_info("SCB_ACQ_START", $sformatf(
                "CTRL.EN 0->1 @cyc %0d : SWEEP=%0d DITHER=%0d SETTLE=%0d THRESH=%0d MINPOW=%0d deadline=%0d cyc",
                cyc, sweep_eff(), dither_eff(), settle_prog, thresh_prog,
                minpow_prog, acq_deadline()), UVM_LOW)
            end
            en_prog = new_en;
          end
          STEP_OFF: begin
            dither_prog = t.wdata[7:0];
            sweep_prog  = t.wdata[15:8];
          end
          SETTLE_OFF:   settle_prog = t.wdata[15:0];
          LOCK_CFG_OFF: begin
            thresh_prog = t.wdata[15:0];
            minpow_prog = t.wdata[31:16];
          end
          default: /* RO or unmapped: no shadow effect */ ;
        endcase
      end
      else begin
        case (t.addr)
          STATUS_OFF: begin
            if (t.rdata[0]) saw_status_locked = 1'b1;
            if (t.rdata[1]) saw_rail_err      = 1'b1;
            if (t.rdata[2]) saw_sweep_err     = 1'b1;
            // ACTIVE == 1 means the FSM is not in S_IDLE (spec 3.1) -- the
            // cheapest software-visible proof that the loop is RUNNING, and
            // half of what stops the negative verdicts being vacuous.
            if (t.rdata[3]) saw_status_active = 1'b1;
          end
          // pd_q is loaded from adc_code in EVERY sample state (spec 2), so a
          // non-zero PD read is direct proof that the DUT digitised light.
          PD_OFF: if (int'(t.rdata[11:0]) > max_pd_read)
                    max_pd_read = int'(t.rdata[11:0]);
          default: /* DAC and the RW registers carry no liveness evidence */ ;
        endcase
      end
    end
  endtask

  // One coherent preponed snapshot of the optical interface per posedge.
  task watch_ring();
    bit          lk;
    int unsigned dac;
    int unsigned adc;
    real         det;
    real         fwhm;
    bit          laser;
    int unsigned span;
    int unsigned jump;
    bit          near_max_prev;
    bit          near_max_now;
    bit          near_zero_prev;
    bit          near_zero_now;

    forever begin
      @(ring_vif.mon_cb);
      if (ring_vif.mon_cb.rst_n !== 1'b1) begin
        lk_prev        = 1'b0;
        dac_prev_valid = 1'b0;
        cyc++;
        continue;
      end

      lk    = ring_vif.mon_cb.locked;
      dac   = int'(ring_vif.mon_cb.dac_code);
      adc   = int'(ring_vif.mon_cb.adc_code);
      det   = ring_vif.mon_cb.detune_code;
      fwhm  = ring_vif.mon_cb.fwhm_code;
      laser = ring_vif.mon_cb.laser_on;

      // ---- LIVENESS evidence ------------------------------------------------
      // The brightest sample the model ever presented, and the spread of codes
      // the DAC visited once an acquisition was armed. Both are consumed by
      // check_loop_ran() so that "never locked" cannot be passed by a DUT that
      // never moved or by a ring that was never lit.
      if (adc > max_adc_seen) max_adc_seen = adc;
      if (acq_armed) begin
        if (!dac_run_valid) begin
          dac_run_lo    = dac;
          dac_run_hi    = dac;
          dac_run_valid = 1'b1;
        end
        else begin
          if (dac < dac_run_lo) dac_run_lo = dac;
          if (dac > dac_run_hi) dac_run_hi = dac;
        end
      end

      // ---- DAC movement -----------------------------------------------------
      if (dac >= DAC_MAX) dac_hit_max = 1'b1;
      if (dac_prev_valid) begin
        jump = (dac > dac_prev) ? (dac - dac_prev) : (dac_prev - dac);
        // A jump larger than the largest programmed step is LEGAL exactly twice:
        // dac_q <- 0 when EN rises and dac_q <- best_code_q when the sweep ends
        // (spec 3.1 / 3.3). It is counted, not flagged; the general no-wrap
        // property is the bound SVA's job. The rail-specific no-wrap check below
        // is armed only where a wrap is unambiguous.
        if (jump > ((sweep_eff() > dither_eff()) ? sweep_eff() : dither_eff()))
          n_big_jumps++;
        // ---- CHECK 5b : saturate without wrapping ---------------------------
        // An integrator wraparound has one unambiguous SIGNATURE: a single-clock
        // EDGE from hard against one rail to hard against the other. It is
        // tested as exactly that.
        //
        // The earlier form flagged any sample with dac + 2*dither_eff < DAC_MAX
        // once the rail had been touched, i.e. any LEVEL below the rail. That is
        // a false-failure generator: two legal downward dither steps (the loop
        // backing off the rail, or the low probe of an iteration whose centre
        // has already moved down) look exactly like a wrap to a level test.
        near_max_prev  = (dac_prev + 2 * dither_eff() >= DAC_MAX);
        near_max_now   = (dac      + 2 * dither_eff() >= DAC_MAX);
        near_zero_prev = (dac_prev <= 2 * dither_eff());
        near_zero_now  = (dac      <= 2 * dither_eff());
        // A fresh acquisition legitimately slams dac_q to 0 (spec 3.1), so the
        // clocks around a CTRL.EN rising edge are excluded.
        if ((m_cfg.exp_outcome == RING_EXP_RAIL_ERR) && dac_hit_max &&
            !rail_wrap_fail && (cyc > en_rise_cyc + 4) &&
            ((near_max_prev && near_zero_now) ||
             (near_zero_prev && near_max_now))) begin
          rail_wrap_fail = 1'b1;
          `uvm_error("SCB_RAIL_WRAP", $sformatf(
            "DAC wrapped around a rail in one clock: %0d -> %0d (DAC_MAX=%0d, dither_eff=%0d)",
            dac_prev, dac, DAC_MAX, dither_eff()))
        end
      end
      dac_prev       = dac;
      dac_prev_valid = 1'b1;

      // ---- lock edges -------------------------------------------------------
      if (lk && !lk_prev) begin
        n_lock_rise++;
        locked_seen   = 1'b1;
        locked_cycles = 0;
        dac_at_lock   = dac;
        dac_lo_seen   = dac;
        dac_hi_seen   = dac;
        if (acq_armed && !acq_done) begin
          acq_done   = 1'b1;
          acq_cycles = cyc - en_rise_cyc;
          `uvm_info("SCB_ACQ_OK", $sformatf(
            "locked after %0d cycles (deadline %0d), dac_code=%0d detune=%0.2f",
            acq_cycles, deadline_cyc - en_rise_cyc, dac, det), UVM_LOW)
        end
      end
      else if (!lk && lk_prev) begin
        lost_lock_any = 1'b1;
        // A lock dropped by a CTRL write (EN 1->0) is intentional, not a loss.
        // The APB stream and this cycle loop are separate processes, so allow a
        // small window around the write before calling it a real lost lock.
        if (en_prog && (cyc > last_ctrl_cyc + 8)) begin
          lost_lock_while_en = 1'b1;
          `uvm_info("SCB_LOCK_LOST", $sformatf(
            "locked fell @cyc %0d after %0d locked cycles (detune=%0.2f)",
            cyc, locked_cycles, det), UVM_MEDIUM)
        end
      end

      // ---- while locked : accuracy + stability ------------------------------
      // Checks 2 and 3 are the LOCK verdict's checks. They are LATCHED for every
      // run (so the report always says what happened) but only ESCALATE to
      // uvm_error where the test documents an optical lock verdict; a run with
      // RING_EXP_NONE (ratio_test) or a negative verdict must not fail on them,
      // and a `locked` that rises in a negative regime is already reported as a
      // false lock by check_phase.
      if (lk) begin
        locked_cycles++;
        if (locked_cycles > max_locked_run) max_locked_run = locked_cycles;
        if (dac < dac_lo_seen) dac_lo_seen = dac;
        if (dac > dac_hi_seen) dac_hi_seen = dac;

        // ---- CHECK 2 : accuracy ---------------------------------------------
        if (laser && (rabs(det) > (fwhm / 2.0))) begin
          accuracy_hits++;
          if (!accuracy_fail) begin
            accuracy_fail = 1'b1;
            if (lock_is_expected())
              `uvm_error("SCB_ACCURACY", $sformatf(
                "locked but off resonance: |detune|=%0.2f > fwhm/2=%0.2f (dac_code=%0d, cyc=%0d)",
                rabs(det), fwhm / 2.0, dac, cyc))
            else
              `uvm_info("SCB_ACCURACY", $sformatf(
                "locked off resonance (|detune|=%0.2f > fwhm/2=%0.2f) - recorded only, %s asserts no accuracy verdict",
                rabs(det), fwhm / 2.0, m_cfg.exp_outcome.name()), UVM_LOW)
          end
        end

        // ---- CHECK 3 : stability --------------------------------------------
        // span(dac_code) == 2*dither_eff on a healthy loop; the limit below is
        // the spec's +/-2*dither_eff on dac_q plus the probe excursion.
        span = dac_hi_seen - dac_lo_seen;
        if (!stability_fail && (span > 6 * dither_eff())) begin
          stability_hits++;
          stability_fail = 1'b1;
          if (lock_is_expected())
            `uvm_error("SCB_STABILITY", $sformatf(
              "dac wandered while locked: span=%0d > 6*dither_eff=%0d (lock dac=%0d, now %0d, %0d locked cycles)",
              span, 6 * dither_eff(), dac_at_lock, dac, locked_cycles))
          else
            `uvm_info("SCB_STABILITY", $sformatf(
              "dac wandered while locked (span=%0d > %0d) - recorded only, %s asserts no stability verdict",
              span, 6 * dither_eff(), m_cfg.exp_outcome.name()), UVM_LOW)
        end
      end

      // ---- CHECK 1 : acquisition deadline -----------------------------------
      if (acq_armed && !acq_done && !deadline_fail && (cyc > deadline_cyc)) begin
        deadline_fail = 1'b1;
        if (lock_is_expected())
          `uvm_error("SCB_NO_ACQ", $sformatf(
            "no lock within the %0d-cycle deadline after CTRL.EN (%s)",
            deadline_cyc - en_rise_cyc, ring_str()))
        else
          `uvm_info("SCB_DEADLINE", $sformatf(
            "acquisition deadline (%0d cycles) elapsed with no lock, as expected for %s",
            deadline_cyc - en_rise_cyc, m_cfg.exp_outcome.name()), UVM_LOW)
      end

      last_det = det;
      lk_prev  = lk;
      cyc++;
    end
  endtask

  // ---- publish the acquisition result for coverage -------------------------
  function void extract_phase(uvm_phase phase);
    photonic_ring_tuner_acq_item it;
    super.extract_phase(phase);
    it             = photonic_ring_tuner_acq_item::type_id::create("acq");
    it.locked_seen = locked_seen;
    // The genuine event, not the intentional CTRL.EN 1->0 at the end of a test.
    it.lost_lock   = lost_lock_while_en;
    it.rail_err    = saw_rail_err;
    it.sweep_err   = saw_sweep_err;
    it.laser_on    = (m_cfg.m_ring_cfg != null) ? m_cfg.m_ring_cfg.laser_on : 1'b1;
    it.settle_prog = int'(settle_prog);
    it.dither_eff  = dither_eff();
    it.acq_cycles  = acq_cycles;
    it.tau_cycles  = (m_cfg.m_ring_cfg != null) ? m_cfg.m_ring_cfg.tau_cycles : 1.0;
    it.res_code    = (m_cfg.m_ring_cfg != null) ? m_cfg.m_ring_cfg.res_code   : 0.0;
    it.fwhm_code   = (m_cfg.m_ring_cfg != null) ? m_cfg.m_ring_cfg.fwhm_code  : 1.0;
    it.ratio       = real'(settle_prog) / ((it.tau_cycles < 1.0) ? 1.0 : it.tau_cycles);
    it.init_detune_pos = (det_at_en >= 0.0);
    acq_ap.write(it);
  endfunction

  // ---- LIVENESS : positive proof that the loop actually RAN ----------------
  // Called for every run that carries an optical verdict. Without it a negative
  // verdict ("`locked` never rose") is passed by a DUT whose `locked` is tied
  // low, whose FSM never leaves S_IDLE, whose dac_code is tied off, or whose
  // photodiode is dead -- i.e. by a DUT that cannot possibly be correct. Every
  // item below is an OBSERVATION THAT MUST HAVE HAPPENED, not an absence.
  function void check_loop_ran(string ctx);
    int unsigned span = dac_run_valid ? (dac_run_hi - dac_run_lo) : 0;

    // (a) an acquisition was started at all
    if (n_en_rise == 0)
      `uvm_error("SCB_NOT_LIVE", $sformatf(
        "%s: no CTRL.EN 0->1 was ever observed, so the loop was never started and this verdict proves nothing",
        ctx))

    // (b) the FSM left S_IDLE (spec 3.1: STATUS.ACTIVE == state_q != S_IDLE)
    if (!saw_status_active)
      `uvm_error("SCB_NOT_LIVE", $sformatf(
        "%s: STATUS.ACTIVE was never read high - the FSM never left S_IDLE (or was never polled while it ran), so this run's verdict is vacuous",
        ctx))

    // (c) the coarse sweep really ramped the heater across the range
    if (span < (DAC_MAX / 2))
      `uvm_error("SCB_NOT_LIVE", $sformatf(
        "%s: dac_code only spanned %0d codes (%0d..%0d) during the acquisition - the coarse sweep did not ramp, so this run's verdict is vacuous (expected a span >= %0d)",
        ctx, span, dac_run_lo, dac_run_hi, DAC_MAX / 2))

    // (d) on a LIT ring, light above MINPOW existed AND the DUT digitised it.
    //     The dark regime deliberately has no light, so this pair is skipped
    //     there -- SWEEP_ERR is that regime's positive evidence instead.
    if (ring_is_lit()) begin
      if (max_adc_seen < int'(minpow_prog))
        `uvm_error("SCB_NOT_LIVE", $sformatf(
          "%s: the model never presented a sample >= MINPOW (max adc_code = %0d, MINPOW = %0d) - there was nothing for the loop to lock ONTO, so this run is the trivial dark-ring case rather than the effect under test (%s)",
          ctx, max_adc_seen, minpow_prog, ring_str()))
      if (max_pd_read == 0)
        `uvm_error("SCB_NOT_LIVE", $sformatf(
          "%s: every PD read returned 0 - pd_q never captured a non-zero ADC sample, so the photodiode path into the DUT is dead and this run's verdict is vacuous",
          ctx))
    end
  endfunction

  // ---- verdict -------------------------------------------------------------
  function void check_phase(uvm_phase phase);
    apb_seq_item leftover;
    super.check_phase(phase);

    // The APB stream is snooped, not paired, so anything still queued is simply
    // drained into the shadow-free path; count it so the activity guard is fair.
    while (apb_fifo.try_get(leftover)) n_apb++;

    `uvm_info("SCB_REPORT", $sformatf(
      "cyc=%0d apb=%0d en_rises=%0d lock_rises=%0d acq_cycles=%0d locked_cycles=%0d max_locked_run=%0d big_jumps=%0d | STATUS seen: locked=%0b active=%0b rail=%0b sweep=%0b | liveness: dac %0d..%0d (span %0d) max_adc=%0d max_pd_read=%0d | ring %s",
      cyc, n_apb, n_en_rise, n_lock_rise, acq_cycles, locked_cycles,
      max_locked_run, n_big_jumps,
      saw_status_locked, saw_status_active, saw_rail_err, saw_sweep_err,
      dac_run_lo, dac_run_hi,
      dac_run_valid ? (dac_run_hi - dac_run_lo) : 0,
      max_adc_seen, max_pd_read,
      ring_str()),
      UVM_LOW)

    if ((cyc == 0) || (n_apb == 0))
      `uvm_error("SCB_NO_ACTIVITY",
                 "scoreboard saw no clocked activity or no APB traffic (no-activity guard)")

    case (m_cfg.exp_outcome)
      // ---- CHECK 1/2/3 ----------------------------------------------------
      RING_EXP_LOCK: begin
        check_loop_ran("RING_EXP_LOCK");
        if (n_lock_rise == 0)
          `uvm_error("SCB_EXP_LOCK", $sformatf(
            "expected an acquisition but `locked` never rose (%s)",
            ring_str()))
        if (lost_lock_while_en)
          `uvm_error("SCB_EXP_LOCK", "lock was lost while the loop was still enabled")
        if (accuracy_fail)
          `uvm_error("SCB_EXP_LOCK", $sformatf(
            "accuracy check failed on %0d locked cycles", accuracy_hits))
        if (stability_fail)
          `uvm_error("SCB_EXP_LOCK", "stability check failed while locked")
        // Check 3 passing is only meaningful if the lock was HELD long enough
        // for a walk-off or a limit cycle to have shown up. A lock that held
        // for a handful of clocks proves nothing about stability.
        if (locked_seen && (max_locked_run < (m_cfg.stability_window / 2)))
          `uvm_error("SCB_LOCK_TOO_SHORT", $sformatf(
            "longest locked run was only %0d clocks (< stability_window/2 = %0d), so the stability check never had a window to observe",
            max_locked_run, m_cfg.stability_window / 2))
      end
      // ---- deliberate lock LOSS (spec 3.4: locked_q is live, not sticky) ---
      RING_EXP_LOCK_THEN_LOSS: begin
        check_loop_ran("RING_EXP_LOCK_THEN_LOSS");
        if (n_lock_rise == 0)
          `uvm_error("SCB_EXP_LOCK", $sformatf(
            "expected an acquisition before the disturbance but `locked` never rose (%s)",
            ring_str()))
        // The loss is the POINT of this test, so it is required, not flagged.
        if (!lost_lock_while_en)
          `uvm_error("SCB_NO_LOCK_LOSS",
                     "the ring was deliberately disturbed while the loop was enabled but `locked` never fell - locked_q is behaving as a STICKY bit (spec 3.4 says it is a live status)")
        if (accuracy_fail)
          `uvm_error("SCB_EXP_LOCK", $sformatf(
            "accuracy check failed on %0d locked cycles", accuracy_hits))
        if (stability_fail)
          `uvm_error("SCB_EXP_LOCK", "stability check failed while locked")
      end
      // ---- CHECK 4 (settle-too-short) --------------------------------------
      RING_EXP_NO_LOCK: begin
        // NEGATIVE verdict: the liveness evidence is what makes it mean
        // anything at all (see check_loop_ran and the file header).
        check_loop_ran("RING_EXP_NO_LOCK");
        if (n_lock_rise != 0)
          `uvm_error("SCB_FALSE_LOCK", $sformatf(
            "`locked` rose %0d time(s) although the ring cannot be acquired in this regime (%s, SETTLE=%0d)",
            n_lock_rise, ring_str(), settle_prog))
        // The regime under test is "the coarse sweep succeeded on a thermally
        // lagged reading and the FINE loop then failed to acquire". If the
        // sweep itself errored out, the run never reached the effect this test
        // claims to prove and its `no lock` is the dark-ring result instead.
        if (saw_sweep_err)
          `uvm_error("SCB_WRONG_FAILURE", $sformatf(
            "STATUS.SWEEP_ERR was set: the coarse sweep found no light at all, so this run never exercised the thermal-lag failure it is supposed to prove (%s, SETTLE=%0d)",
            ring_str(), settle_prog))
      end
      // ---- CHECK 4 (dark fibre) -------------------------------------------
      RING_EXP_SWEEP_ERR: begin
        check_loop_ran("RING_EXP_SWEEP_ERR");
        if (n_lock_rise != 0)
          `uvm_error("SCB_FALSE_LOCK", $sformatf(
            "`locked` rose %0d time(s) on a DARK ring - the MINPOW guard failed (spec 3.4)",
            n_lock_rise))
        if (!saw_sweep_err)
          `uvm_error("SCB_NO_SWEEP_ERR",
                     "expected STATUS.SWEEP_ERR to be set after a sweep that found no light")
      end
      // ---- CHECK 5 ---------------------------------------------------------
      RING_EXP_RAIL_ERR: begin
        check_loop_ran("RING_EXP_RAIL_ERR");
        if (!saw_rail_err)
          `uvm_error("SCB_NO_RAIL_ERR",
                     "expected STATUS.RAIL_ERR after the loop pushed past DAC_MAX")
        if (!dac_hit_max)
          `uvm_error("SCB_NO_SATURATION", $sformatf(
            "the DAC never reached DAC_MAX (%0d) although the resonance is beyond it",
            DAC_MAX))
        if (rail_wrap_fail)
          `uvm_error("SCB_RAIL_WRAP", "the DAC wrapped instead of saturating")
        if (n_lock_rise != 0)
          `uvm_error("SCB_FALSE_LOCK", $sformatf(
            "`locked` rose %0d time(s) while the loop was hard against the rail",
            n_lock_rise))
      end
      default: /* RING_EXP_NONE : register-only test, no optical verdict */ ;
    endcase
  endfunction

endclass

`endif // PHOTONIC_RING_TUNER_SCOREBOARD_SVH
