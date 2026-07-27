// -----------------------------------------------------------------------------
// photonic_ring_tuner_vseq_lib.svh : virtual-sequence library layered over the
//   RAL and the APB sequencer. Every vseq extends photonic_ring_tuner_base_vseq,
//   which carries the RAL block, a virtual apb_if (for cycle waits), a virtual
//   ring_if (to watch the optical loop) and the env config.
//
//   THE LOOP IS CLOSED, so these sequences look different from a normal register
//   IP's: there is no data stream to drive. A vseq PROGRAMS the loop over the
//   RAL, ENABLES it, and then WAITS FOR A PHYSICAL OUTCOME (lock / sweep error /
//   rail error) that the randomized ring produces on its own through ring_model.
//
//   vseqs:
//     photonic_ring_tuner_base_vseq          - handles + register/optical helpers
//     photonic_ring_tuner_smoke_vseq         - reset values, RW/RO/W1C behaviour
//     photonic_ring_tuner_reg_vseq           - uvm_reg_hw_reset_seq + bit_bash
//     photonic_ring_tuner_lock_vseq          - cold acquisition + hold + re-acquire
//     photonic_ring_tuner_lock_loss_vseq     - acquire, then BREAK the lock
//     photonic_ring_tuner_settle_short_vseq  - SETTLE < tau : must NOT acquire
//     photonic_ring_tuner_dark_vseq          - laser off  : SWEEP_ERR, no lock
//     photonic_ring_tuner_rail_vseq          - resonance past DAC_MAX : RAIL_ERR
//     photonic_ring_tuner_rail_w1c_race_vseq - W1C vs HW-set race on RAIL_ERR
//     photonic_ring_tuner_error_vseq         - unmapped/unaligned/RO accesses
//     photonic_ring_tuner_ratio_vseq         - sweeps SETTLE/tau for coverage
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_VSEQ_LIB_SVH
`define PHOTONIC_RING_TUNER_VSEQ_LIB_SVH

// ---------------------------------------------------------------------------
class photonic_ring_tuner_base_vseq extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(photonic_ring_tuner_base_vseq)

  photonic_ring_tuner_reg_block regmodel;   // set by the test
  virtual apb_if                vif;        // set by the test (cycle waits)
  virtual ring_if               ring_vif;   // set by the test (optical loop)
  photonic_ring_tuner_env_cfg   m_cfg;      // set by the test

  // register byte offsets (spec 2), for the raw/illegal accesses
  localparam bit [7:0] CTRL_OFF     = 8'h00;
  localparam bit [7:0] STEP_OFF     = 8'h04;
  localparam bit [7:0] SETTLE_OFF   = 8'h08;
  localparam bit [7:0] LOCK_CFG_OFF = 8'h0C;
  localparam bit [7:0] STATUS_OFF   = 8'h10;
  localparam bit [7:0] DAC_OFF      = 8'h14;
  localparam bit [7:0] PD_OFF       = 8'h18;

  localparam int unsigned DAC_MAX = 4095;

  // Shadow of what THIS sequence programmed, so the observation windows can be
  // sized from the same deadline formula the scoreboard enforces.
  int unsigned settle_now = 32;
  int unsigned dither_now = 4;
  int unsigned sweep_now  = 32;

  bit          false_lock_reported;

  // ---- LIVENESS evidence gathered while watching a NEGATIVE outcome -------
  // A test that only ever asserts "`locked` never rose" passes on a DUT that
  // does nothing at all. These fields record the POSITIVE observations that
  // prove the loop ran, and assert_loop_ran() turns their absence into an
  // error. The scoreboard makes the same judgement per-CLOCK and owns the final
  // verdict; this copy exists so the vseq's own log says why it believes the
  // run was real.
  bit          saw_active_probe;    // STATUS.ACTIVE read high
  int unsigned max_pd_probe;        // largest PD (pd_q) value read back
  int unsigned dac_lo_probe;
  int unsigned dac_hi_probe;
  bit          probe_valid;

  function new(string name = "photonic_ring_tuner_base_vseq");
    super.new(name);
  endfunction

  // ---- generic waits -------------------------------------------------------
  task wait_cycles(int unsigned n);
    if (vif == null) return;
    repeat (n) @(posedge vif.clk);
  endtask

  // ---- RAL front-door helpers ---------------------------------------------
  task write_reg(uvm_reg r, uvm_reg_data_t data);
    uvm_status_e st;
    r.write(st, data, .parent(this));
    if (st != UVM_IS_OK)
      `uvm_error("VSEQ_WR", $sformatf("write of %s not OK", r.get_name()))
  endtask

  task read_reg(uvm_reg r, output uvm_reg_data_t data);
    uvm_status_e st;
    r.read(st, data, .parent(this));
    if (st != UVM_IS_OK)
      `uvm_error("VSEQ_RD", $sformatf("read of %s not OK", r.get_name()))
  endtask

  // Read a register and self-check its value against exp (mask applied).
  task check_reg(uvm_reg r, uvm_reg_data_t exp, uvm_reg_data_t mask = 32'hFFFF_FFFF);
    uvm_reg_data_t got;
    read_reg(r, got);
    if ((got & mask) !== (exp & mask))
      `uvm_error("VSEQ_CHK", $sformatf("%s read=0x%08h exp=0x%08h (mask=0x%08h)",
                 r.get_name(), got, exp, mask))
    else
      `uvm_info("VSEQ_CHK", $sformatf("%s == 0x%08h OK", r.get_name(), exp & mask),
                UVM_MEDIUM)
  endtask

  // Raw APB access (bypasses RAL; used for illegal / RO / reserved stimulus).
  task raw_access(apb_dir_e dir, bit [7:0] addr, bit [31:0] wdata,
                  output apb_seq_item done);
    apb_seq_item tr = apb_seq_item::type_id::create("raw");
    start_item(tr);
    tr.dir   = dir;
    tr.addr  = addr;
    tr.wdata = wdata;
    finish_item(tr);
    done = tr;
  endtask

  // ---- loop programming ----------------------------------------------------
  task program_step(int unsigned dither, int unsigned sweep);
    write_reg(regmodel.STEP, ((sweep & 32'hFF) << 8) | (dither & 32'hFF));
    dither_now = dither;
    sweep_now  = sweep;
  endtask

  task program_settle(int unsigned settle);
    write_reg(regmodel.SETTLE, settle & 32'hFFFF);
    settle_now = settle;
  endtask

  task program_lock_cfg(int unsigned thresh, int unsigned minpow);
    write_reg(regmodel.LOCK_CFG, ((minpow & 32'hFFFF) << 16) | (thresh & 32'hFFFF));
  endtask

  task enable_loop();
    write_reg(regmodel.CTRL, 32'h1);
  endtask

  task disable_loop();
    write_reg(regmodel.CTRL, 32'h0);
  endtask

  function int unsigned dither_eff();
    return (dither_now == 0) ? 1 : dither_now;
  endfunction

  function int unsigned sweep_eff();
    return (sweep_now == 0) ? 1 : sweep_now;
  endfunction

  // The one deadline definition (env_cfg), sized from what we programmed.
  function int unsigned deadline_cycles();
    return m_cfg.acq_deadline(settle_now, sweep_eff(), dither_eff());
  endfunction

  // ---- liveness probes -----------------------------------------------------
  // One STATUS read : records STATUS.ACTIVE (spec 3.1 -- the FSM is not in
  // S_IDLE), which is the cheapest software-visible proof that the loop is
  // RUNNING. Returns the value so callers can reuse it.
  task probe_status(output uvm_reg_data_t d);
    read_reg(regmodel.STATUS, d);
    if (d[3]) saw_active_probe = 1'b1;
  endtask

  // One DAC + PD read : records the spread of centre codes the sweep visited
  // and the brightest sample the DUT itself digitised (pd_q is loaded in EVERY
  // sample state, spec 2).
  task probe_dac_pd();
    uvm_reg_data_t d;
    int unsigned   v;
    read_reg(regmodel.DAC, d);
    v = int'(d & 32'h0000_0FFF);
    if (!probe_valid) begin
      dac_lo_probe = v;
      dac_hi_probe = v;
      probe_valid  = 1'b1;
    end
    else begin
      if (v < dac_lo_probe) dac_lo_probe = v;
      if (v > dac_hi_probe) dac_hi_probe = v;
    end
    read_reg(regmodel.PD, d);
    v = int'(d & 32'h0000_0FFF);
    if (v > max_pd_probe) max_pd_probe = v;
  endtask

  task probe_liveness();
    uvm_reg_data_t d;
    probe_status(d);
    probe_dac_pd();
  endtask

  // Turn missing evidence into a failure. `lit` says whether the ring has any
  // light to find at all: the DARK regime deliberately has none, so there the
  // photodiode evidence does not apply and SWEEP_ERR is the positive proof
  // instead. The thresholds here are deliberately looser than the scoreboard's,
  // because these come from SAMPLED register reads rather than a per-clock
  // observation.
  function void assert_loop_ran(string why, bit lit = 1'b1);
    int unsigned span = probe_valid ? (dac_hi_probe - dac_lo_probe) : 0;
    if (!saw_active_probe)
      `uvm_error("VSEQ_NOT_LIVE", $sformatf(
        "%s: STATUS.ACTIVE never read high, so the FSM never left S_IDLE and this run proves nothing",
        why))
    if (span < (DAC_MAX / 4))
      `uvm_error("VSEQ_NOT_LIVE", $sformatf(
        "%s: the DAC register only spanned %0d codes (%0d..%0d) - the coarse sweep never ramped",
        why, span, dac_lo_probe, dac_hi_probe))
    if (lit && (max_pd_probe == 0)) begin
      `uvm_error("VSEQ_NOT_LIVE", $sformatf(
        "%s: every PD read returned 0 on a LIT ring - the photodiode path into the DUT is dead",
        why))
    end
    `uvm_info("VSEQ_LIVE", $sformatf(
      "%s: evidence the loop ran -> ACTIVE seen=%0b, DAC spanned %0d codes (%0d..%0d), max PD read=%0d",
      why, saw_active_probe, span, dac_lo_probe, dac_hi_probe, max_pd_probe),
      UVM_LOW)
  endfunction

  // ---- optical-outcome helpers --------------------------------------------
  // Apply (or re-apply) the physics to the model, e.g. after changing the laser.
  function void apply_ring(ring_cfg c);
    if (c != null) c.apply(ring_vif);
  endfunction

  task set_laser(bit on);
    if (ring_vif == null) return;
    ring_vif.laser_on = on;
    if (m_cfg != null && m_cfg.m_ring_cfg != null) m_cfg.m_ring_cfg.laser_on = on;
  endtask

  function bit locked_now();
    return (ring_vif == null) ? 1'b0 : ring_vif.locked;
  endfunction

  // Wait (up to max_cycles) for `locked` to be high.
  task wait_lock(int unsigned max_cycles, output bit got);
    int unsigned n = 0;
    got = 1'b0;
    while ((n < max_cycles) && !got) begin
      @(ring_vif.mon_cb);
      if (ring_vif.mon_cb.locked) got = 1'b1;
      n++;
    end
  endtask

  // Watch the loop for n clocks and FAIL IMMEDIATELY if `locked` ever rises.
  // The scoreboard makes the same judgement at the end of the run; doing it here
  // too means the first failing cycle is in the log, next to the waveform.
  //
  // "`locked` never rose" is a NEGATIVE statement and is satisfied by a DUT that
  // does nothing, so with probe_every != 0 the watch also interleaves a
  // STATUS/DAC/PD read every probe_every clocks to collect the POSITIVE
  // evidence assert_loop_ran() demands. Those reads cost a few clocks each, so
  // this task's own false-lock watch has small gaps in them -- harmless,
  // because the scoreboard samples ring_if on EVERY clock and owns the verdict.
  task observe_no_lock(int unsigned n, string why, int unsigned probe_every = 0);
    int unsigned i;
    for (i = 0; i < n; i++) begin
      @(ring_vif.mon_cb);
      if (ring_vif.mon_cb.locked && !false_lock_reported) begin
        false_lock_reported = 1'b1;
        `uvm_error("VSEQ_FALSE_LOCK", $sformatf(
          "`locked` rose %0d cycles after enable, but %s (ring: %s, SETTLE=%0d)",
          i, why, m_cfg.m_ring_cfg.convert2string(), settle_now))
      end
      if ((probe_every != 0) && ((i % probe_every) == (probe_every - 1)))
        probe_liveness();
    end
  endtask

  // Poll STATUS over the bus until bit `idx` reads 1 (or the budget runs out).
  // With watch_lock set, the waiting between polls is spent WATCHING the loop,
  // so a false lock is caught at the cycle it happens rather than afterwards.
  // Deliberately single-threaded: a `disable fork` here could tear down a RAL
  // access mid-item and leave the sequencer holding a dangling request.
  task wait_status_bit(int unsigned idx, int unsigned max_cycles, bit watch_lock,
                       string why, output bit got);
    uvm_reg_data_t d;
    int unsigned   waited = 0;
    got = 1'b0;
    while ((waited < max_cycles) && !got) begin
      probe_status(d);            // reads STATUS and records ACTIVE
      if (d[idx]) got = 1'b1;
      else begin
        probe_dac_pd();           // liveness: DAC spread + brightest pd_q
        if (watch_lock) observe_no_lock(32, why);
        else            wait_cycles(32);
        waited += 32;
      end
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// Smoke : reset values of all seven registers, RW readback of the multi-field
//   registers, reserved bits read 0 / ignore writes, RO writes silently dropped,
//   W1C on an idle STATUS is a no-op.
class photonic_ring_tuner_smoke_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_smoke_vseq)
  function new(string name = "photonic_ring_tuner_smoke_vseq"); super.new(name); endfunction

  task body();
    apb_seq_item it;
    regmodel.reset();                       // mirror -> reset

    // ---- spec-2 reset values ----
    check_reg(regmodel.CTRL,     32'h0000_0000);
    check_reg(regmodel.STEP,     32'h0000_2004);
    check_reg(regmodel.SETTLE,   32'h0000_0020);
    check_reg(regmodel.LOCK_CFG, 32'h0100_0008);
    check_reg(regmodel.STATUS,   32'h0000_0000);
    check_reg(regmodel.DAC,      32'h0000_0000);
    check_reg(regmodel.PD,       32'h0000_0000);

    // ---- RW readback of the multi-field registers ----
    // A TINY step pair first: a SWEEP in 1..7 is otherwise never programmed
    // anywhere in the suite, which would leave cg_step.cp_sweep.tiny (and every
    // x_step cell containing it) permanently empty. The loop is never enabled
    // in smoke, so this is a pure register readback with no loop cost.
    program_step(8'h02, 8'h05);                       // DITHER=0x02 SWEEP=0x05
    check_reg(regmodel.STEP, 32'h0000_0502);
    program_step(8'h10, 8'h08);                       // DITHER=0x10 SWEEP=0x08
    check_reg(regmodel.STEP, 32'h0000_0810);
    program_settle(16'h0040);
    check_reg(regmodel.SETTLE, 32'h0000_0040);
    program_lock_cfg(16'h0020, 16'h0200);
    check_reg(regmodel.LOCK_CFG, 32'h0200_0020);

    // ---- reserved bits read 0 and ignore writes (raw: RAL would mask them) ----
    raw_access(APB_WRITE, STEP_OFF, 32'hFFFF_0810, it);
    if (it.slverr) `uvm_error("VSEQ_SMOKE", "write to STEP reserved bits raised pslverr")
    check_reg(regmodel.STEP, 32'h0000_0810);
    raw_access(APB_WRITE, SETTLE_OFF, 32'hFFFF_0040, it);
    check_reg(regmodel.SETTLE, 32'h0000_0040);

    // ---- RO registers : writes are SILENTLY dropped (no pslverr, no effect) ----
    raw_access(APB_WRITE, DAC_OFF, 32'h0000_0FFF, it);
    if (it.slverr) `uvm_error("VSEQ_SMOKE", "write to RO DAC raised pslverr (should not)")
    check_reg(regmodel.DAC, 32'h0000_0000);
    raw_access(APB_WRITE, PD_OFF, 32'h0000_0FFF, it);
    if (it.slverr) `uvm_error("VSEQ_SMOKE", "write to RO PD raised pslverr (should not)")
    check_reg(regmodel.PD, 32'h0000_0000);

    // ---- STATUS : W1C with nothing set leaves it at 0, RO bits unaffected ----
    raw_access(APB_WRITE, STATUS_OFF, 32'hFFFF_FFFF, it);
    if (it.slverr) `uvm_error("VSEQ_SMOKE", "W1C write to STATUS raised pslverr")
    check_reg(regmodel.STATUS, 32'h0000_0000);

    // ---- restore the spec-2 defaults ----
    program_step(8'h04, 8'h20);
    program_settle(16'h0020);
    program_lock_cfg(16'h0008, 16'h0100);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// RAL showcase : the built-in hw-reset and bit-bash register sequences. STATUS,
//   DAC and PD are excluded from both (NO_REG_BIT_BASH_TEST + the volatile
//   fields are set_compare(UVM_NO_CHECK) and the registers carry
//   NO_REG_HW_RESET_TEST) because all three are hardware-updated.
//
//   THE LOOP IS *NOT* DISABLED THROUGHOUT -- an earlier comment here claimed it
//   was, and that was simply false. `uvm_reg_bit_bash_seq` bashes CTRL like any
//   other RW register, so it DOES write CTRL.EN = 1 for one beat, which starts a
//   real acquisition (spec 3.1: a rising edge of en_q resets dac_q to 0 and
//   enters the coarse sweep).
//
//   Why that is harmless here, precisely: SETTLE is still at its reset value of
//   32, so the FSM sits in S_SWEEP_WAIT counting settle clocks. bit-bash's very
//   next bus operations (the read-back and the restoring write) complete in far
//   fewer than 32 clocks, so EN falls again before the FSM ever reaches
//   S_SWEEP_SAMP: no ADC sample is taken, dac_q never advances past 0, and no
//   sticky flag can be set. The final check_reg(STATUS, 0) at the end of this
//   body is what actually PROVES that -- if a future change to SETTLE (or a
//   slower bus) let the sweep start sampling, STATUS would no longer read 0 and
//   this vseq would fail rather than silently drift.
class photonic_ring_tuner_reg_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_reg_vseq)
  function new(string name = "photonic_ring_tuner_reg_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_hw_reset_seq hw;
    uvm_reg_bit_bash_seq bb;

    regmodel.reset();
    disable_loop();                  // start the walk from a quiescent S_IDLE
    wait_cycles(5);

    hw = uvm_reg_hw_reset_seq::type_id::create("hw");
    hw.model = regmodel;
    hw.start(null);

    bb = uvm_reg_bit_bash_seq::type_id::create("bb");
    bb.model = regmodel;
    bb.start(null);

    // bit-bash leaves the programmable registers at their reset values; put the
    // loop back to a known state and prove that the momentary CTRL.EN = 1 the
    // bash issued (see the header) never got far enough to sample the ADC or to
    // set a sticky flag.
    disable_loop();
    program_step(8'h04, 8'h20);
    program_settle(16'h0020);
    program_lock_cfg(16'h0008, 16'h0100);
    check_reg(regmodel.STATUS, 32'h0000_0000);
    check_reg(regmodel.DAC,    32'h0000_0000);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Lock from cold : DEFAULT register settings on a randomized, reachable ring.
//   Acquire, HOLD (so the scoreboard's stability window has something to look
//   at), then disable and re-acquire. The re-acquisition starts with the heater
//   still hot, i.e. with the OPPOSITE initial detuning sign to the cold start -
//   the other half of the spec-7.6 sign coverpoint.
class photonic_ring_tuner_lock_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_lock_vseq)
  function new(string name = "photonic_ring_tuner_lock_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    uvm_reg_data_t lock_cfg_rd;
    uvm_reg_data_t minpow;
    bit            got;

    regmodel.reset();
    // DEFAULT step / settle / lock criteria -- the ring_cfg LOCKABLE regime is
    // constrained so exactly these settings can acquire it (see env_cfg).
    check_reg(regmodel.STEP,     32'h0000_2004);
    check_reg(regmodel.SETTLE,   32'h0000_0020);
    check_reg(regmodel.LOCK_CFG, 32'h0100_0008);

    `uvm_info("VSEQ_LOCK", $sformatf("acquiring %s (deadline %0d cycles)",
              m_cfg.m_ring_cfg.convert2string(), deadline_cycles()), UVM_LOW)

    enable_loop();
    wait_lock(deadline_cycles(), got);
    if (!got)
      `uvm_error("VSEQ_LOCK", $sformatf(
        "no lock within %0d cycles from cold (%s)",
        deadline_cycles(), m_cfg.m_ring_cfg.convert2string()))

    // ---- hold : the scoreboard checks accuracy + stability across this window
    wait_cycles(m_cfg.stability_window);

    // ---- the register view of a locked loop ----
    check_reg(regmodel.STATUS, 32'h0000_0009, 32'h0000_0009);  // LOCKED | ACTIVE
    read_reg(regmodel.DAC, d);
    `uvm_info("VSEQ_LOCK", $sformatf("DAC=%0d PD reads next", d), UVM_MEDIUM)
    // ---- PD while the loop is RUNNING -------------------------------------
    // Spec 2 makes pd_q the most recent ADC sample in EVERY sample state (and
    // the bound SVA enforces it: p_pd_captures_adc / spec 5.3a requires pd_q
    // >= minpow_q at the S_UPDATE that raises locked_q), so PD is contractual
    // here rather than informational.
    //
    // The sample PD carries was taken at a PROBE code (dac_q +/- dither_eff),
    // not at the centre, so the value asserted is exactly the one the lock rule
    // itself demands of BOTH probes -- >= MINPOW -- and no more. MINPOW is read
    // back from LOCK_CFG rather than hard-coded, so the check tracks whatever
    // was programmed. Gated on the loop still being locked at the moment of the
    // read: if the lock had just dropped, pd_q would legitimately be a dark
    // sample and the scoreboard's lost-lock check owns that failure instead.
    read_reg(regmodel.LOCK_CFG, lock_cfg_rd);
    minpow = (lock_cfg_rd >> 16) & 32'h0000_FFFF;
    read_reg(regmodel.PD, d);
    if (locked_now() && (d < minpow))
      `uvm_error("VSEQ_LOCK", $sformatf(
        "locked but PD=0x%0h is below MINPOW=0x%0h - the probe that produced it was too dark",
        d, minpow))
    else
      `uvm_info("VSEQ_LOCK", $sformatf("PD=0x%0h >= MINPOW=0x%0h while locked",
                d, minpow), UVM_MEDIUM)

    // ---- disable : the heater HOLDS its bias (spec 3.1), so the re-acquisition
    //      starts hot -> initial detuning of the opposite sign.
    disable_loop();
    wait_cycles(64);
    check_reg(regmodel.STATUS, 32'h0000_0000, 32'h0000_0009);  // !LOCKED, !ACTIVE

    enable_loop();
    wait_lock(deadline_cycles(), got);
    if (!got)
      `uvm_error("VSEQ_LOCK", $sformatf(
        "no lock within %0d cycles on RE-acquisition (%s)",
        deadline_cycles(), m_cfg.m_ring_cfg.convert2string()))
    wait_cycles(m_cfg.stability_window / 4);
    disable_loop();
    wait_cycles(16);
  endtask
endclass

// ---------------------------------------------------------------------------
// LOCK LOSS (directed) : acquire a lock, then BREAK it on purpose and check the
//   loop responds correctly.
//
//   Spec 3.4 makes `locked_q` a LIVE status, not a sticky one: it must deassert
//   as soon as a single fine iteration is not at peak. Nothing else in the suite
//   ever breaks an established lock, so before this vseq existed the
//   `cp_outcome.lost_lock` bin (spec 7.6, and the SVA's "lock lost after having
//   been acquired" cover point) was unfillable, and in lock_test a lost lock is
//   itself a uvm_error. Coverage that cannot fill is a coverage lie.
//
//   The disturbance is the LASER, switched off with the loop still enabled and
//   still locked. That is the cleanest break available:
//     * it is instantaneous (laser_on gates `trans` directly -- no thermal lag
//       to wait out), so the response window is short and deterministic;
//     * both probes collapse to read-noise, so at_peak fails on the MINPOW term
//       (spec 3.4) -- exactly the guard this IP exists to get right -- and
//       `locked` must fall within one fine iteration;
//     * the LOCKABLE regime allows at most 2 LSB of noise while THRESH is 8, so
//       neither move_up nor move_down can assert on noise alone: dac_q stays
//       parked on the resonance while the fibre is dark.
//   Switching the laser back on must therefore re-acquire from where it stands,
//   with no re-sweep and no CTRL write -- which is the other half of the check:
//   the loop RECOVERS rather than latching a failure.
class photonic_ring_tuner_lock_loss_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_lock_loss_vseq)
  function new(string name = "photonic_ring_tuner_lock_loss_vseq"); super.new(name); endfunction

  // One fine iteration is HI_WAIT + HI_SAMP + LO_WAIT + LO_SAMP + UPDATE =
  // 2*(SETTLE+2)+3 clocks (spec 3.2).
  function int unsigned fine_iter_cycles();
    return 2 * (settle_now + 2) + 3;
  endfunction

  task body();
    uvm_reg_data_t d;
    bit            got;
    int unsigned   i;
    int unsigned   fell_after;
    int unsigned   budget;

    regmodel.reset();
    // DEFAULT step / settle / lock criteria on a LOCKABLE ring, exactly as
    // lock_vseq: this test is about what happens AFTER the lock.
    check_reg(regmodel.STEP,     32'h0000_2004);
    check_reg(regmodel.SETTLE,   32'h0000_0020);
    check_reg(regmodel.LOCK_CFG, 32'h0100_0008);

    `uvm_info("VSEQ_LOSS", $sformatf("acquiring %s (deadline %0d cycles)",
              m_cfg.m_ring_cfg.convert2string(), deadline_cycles()), UVM_LOW)

    enable_loop();
    wait_lock(deadline_cycles(), got);
    if (!got)
      `uvm_error("VSEQ_LOSS", $sformatf(
        "no lock within %0d cycles from cold (%s) - cannot break a lock that never happened",
        deadline_cycles(), m_cfg.m_ring_cfg.convert2string()))

    // Hold briefly and take the register view of a locked, running loop. This
    // is also the liveness evidence the scoreboard requires.
    wait_cycles(m_cfg.stability_window / 4);
    probe_status(d);
    if ((d & 32'h0000_0009) !== 32'h0000_0009)
      `uvm_error("VSEQ_LOSS", $sformatf(
        "expected STATUS.LOCKED and STATUS.ACTIVE before the disturbance, read 0x%08h", d))
    probe_dac_pd();

    // ---- BREAK IT : the fibre goes dark with the loop still enabled --------
    `uvm_info("VSEQ_LOSS",
              "switching the laser OFF with the loop enabled and locked", UVM_LOW)
    set_laser(1'b0);

    // `locked` must fall. One fine iteration is enough in principle; allow
    // four, plus the in-flight iteration, before calling it a stuck bit.
    budget     = 5 * fine_iter_cycles() + 64;
    fell_after = 0;
    for (i = 0; i < budget; i++) begin
      @(ring_vif.mon_cb);
      if (!ring_vif.mon_cb.locked) begin
        fell_after = i;
        break;
      end
    end
    if (locked_now())
      `uvm_error("VSEQ_LOSS", $sformatf(
        "`locked` is STILL high %0d cycles after the fibre went dark - locked_q is sticky, but spec 3.4 makes it a live status that must deassert on the first iteration that is not at peak",
        budget))
    else
      `uvm_info("VSEQ_LOSS", $sformatf(
        "`locked` fell %0d cycles after the laser dropped (one fine iteration is %0d cycles)",
        fell_after, fine_iter_cycles()), UVM_LOW)

    // The software view must agree: LOCKED clear, ACTIVE still set (the loop is
    // still enabled and still dithering), and no error flag invented.
    read_reg(regmodel.STATUS, d);
    if (d[0])
      `uvm_error("VSEQ_LOSS", $sformatf(
        "STATUS.LOCKED still reads 1 after the lock was broken (STATUS=0x%08h)", d))
    if (!d[3])
      `uvm_error("VSEQ_LOSS", $sformatf(
        "STATUS.ACTIVE fell too: losing lock must not stop the loop (STATUS=0x%08h)", d))
    if (d[1] || d[2])
      `uvm_error("VSEQ_LOSS", $sformatf(
        "a sticky error flag was set by a plain lock loss (STATUS=0x%08h)", d))

    // The dark loop must not walk away either: with both probes at read-noise
    // and THRESH = 8, neither move_up nor move_down can assert.
    read_reg(regmodel.DAC, d);
    `uvm_info("VSEQ_LOSS", $sformatf("DAC parked at %0d while dark", d), UVM_LOW)

    // ---- and it must RECOVER once the light comes back ---------------------
    set_laser(1'b1);
    wait_lock(8 * fine_iter_cycles() + 256, got);
    if (!got)
      `uvm_error("VSEQ_LOSS", $sformatf(
        "the loop did not re-acquire after the laser came back on, although dac_q never left the resonance (%s)",
        m_cfg.m_ring_cfg.convert2string()))
    else
      `uvm_info("VSEQ_LOSS", "re-acquired without a re-sweep, as expected", UVM_LOW)

    wait_cycles(m_cfg.stability_window / 4);
    disable_loop();
    wait_cycles(16);
  endtask
endclass

// ---------------------------------------------------------------------------
// THE headline negative test : SETTLE programmed far BELOW the ring's thermal
//   time constant. The controller then samples the photodiode before the ring
//   has reached the commanded temperature, so the coarse sweep records its peak
//   at a DAC code offset by the whole thermal lag and the fine loop engages on
//   completely the wrong side of the resonance. `locked` MUST NEVER RISE - the
//   MINPOW term (spec 3.4) is the only thing standing between this situation and
//   a confident, completely wrong lock.
//
//   "`locked` never rose" ON ITS OWN IS NOT A RESULT. It is satisfied by a DUT
//   whose `locked` is tied low, whose FSM never leaves S_IDLE, whose dac_code is
//   tied off, or whose photodiode is dead -- i.e. by every broken DUT as well as
//   the correct one. So the watch below also PROBES the loop while it runs
//   (STATUS.ACTIVE, the DAC's spread, the brightest pd_q the DUT digitised) and
//   assert_loop_ran() fails the test if that positive evidence is missing. The
//   scoreboard repeats the judgement per-clock and additionally requires that
//   the coarse sweep did NOT end in SWEEP_ERR, so this test can only pass by
//   demonstrating the failure mode it claims: a loop that ran, found light, and
//   still could not acquire.
class photonic_ring_tuner_settle_short_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_settle_short_vseq)

  // SETTLE = 1 while tau is 400..800 cycles => ratio ~ 0.002, deep in the
  // "sampled before the ring settled" bin.
  rand int unsigned settle_prog_val;
  constraint c_settle { settle_prog_val inside {[1:2]}; }

  function new(string name = "photonic_ring_tuner_settle_short_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;

    regmodel.reset();
    program_settle(settle_prog_val);
    check_reg(regmodel.SETTLE, settle_prog_val);

    `uvm_info("VSEQ_SETTLE", $sformatf(
      "SETTLE=%0d vs tau=%0.1f cycles (ratio %0.4f) : the loop must NOT acquire (%s)",
      settle_prog_val, m_cfg.m_ring_cfg.tau_cycles,
      m_cfg.m_ring_cfg.settle_ratio(settle_prog_val),
      m_cfg.m_ring_cfg.convert2string()), UVM_LOW)

    enable_loop();
    // Watch for twice as long as a properly settled loop would need to acquire,
    // probing the loop every 48 clocks for the positive evidence that it is
    // actually running (see the header).
    observe_no_lock(2 * deadline_cycles(),
                    "SETTLE is far below the thermal time constant", 48);

    // Record where it ended up, and fold the final reads into the evidence.
    probe_status(d);
    `uvm_info("VSEQ_SETTLE", $sformatf("final STATUS=0x%08h", d), UVM_LOW)
    if (d[2])
      `uvm_error("VSEQ_SETTLE", $sformatf(
        "STATUS.SWEEP_ERR is set: the coarse sweep found no light at all, so this run never reached the thermal-lag failure it exists to prove (%s)",
        m_cfg.m_ring_cfg.convert2string()))
    probe_dac_pd();
    `uvm_info("VSEQ_SETTLE", $sformatf("DAC visited %0d..%0d over the run",
              dac_lo_probe, dac_hi_probe), UVM_LOW)

    // ---- the loop RAN and still did not acquire : THAT is the result -------
    // Without this line the whole test is "nothing happened", which every
    // broken DUT also satisfies.
    assert_loop_ran("settle_short (SETTLE far below tau)", 1'b1);

    disable_loop();
    wait_cycles(16);
  endtask
endclass

// ---------------------------------------------------------------------------
// Dark fibre : laser_on = 0, so the photodiode reads noise only. The sweep must
//   find nothing above MINPOW anywhere in the tuning range and report SWEEP_ERR,
//   and `locked` must never rise - far off resonance the two dither probes are
//   EQUAL (both ~0), so a gradient-only lock rule would declare a false lock
//   here (spec 3.4). Then W1C-clear the sticky flag.
class photonic_ring_tuner_dark_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_dark_vseq)
  function new(string name = "photonic_ring_tuner_dark_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    apb_seq_item   it;
    bit            got;

    regmodel.reset();
    set_laser(1'b0);                    // belt and braces: the cfg is already dark
    wait_cycles(4);

    enable_loop();
    wait_status_bit(2, 2 * deadline_cycles(), 1'b1,          // STATUS.SWEEP_ERR
                    "the fibre is dark and there is no resonance to find", got);

    if (!got) begin
      read_reg(regmodel.STATUS, d);
      if (!d[2])
        `uvm_error("VSEQ_DARK", $sformatf(
          "no SWEEP_ERR after sweeping a dark ring (STATUS=0x%08h)", d))
    end
    if (locked_now())
      `uvm_error("VSEQ_DARK", "`locked` is high on a dark ring (false lock)")

    // The "never locked" half of this test is negative, so demand the positive
    // half too: the sweep must actually have RAMPED the heater across the range
    // before reporting that it found nothing. `lit` is 0 -- on a dark fibre
    // there is by construction no light for pd_q to capture, and SWEEP_ERR
    // (checked above) is this regime's positive evidence instead.
    assert_loop_ran("dark fibre (laser off)", 1'b0);

    // ---- sticky + W1C : disable first so hardware cannot re-set the flag, then
    //      write 0 (no effect) and finally write 1 (clears).
    disable_loop();
    wait_cycles(16);
    raw_access(APB_WRITE, STATUS_OFF, 32'h0000_0000, it);   // W1C of 0 : no effect
    wait_cycles(2);
    check_reg(regmodel.STATUS, 32'h0000_0004, 32'h0000_0004);   // still set
    write_reg(regmodel.STATUS, 32'h0000_0004);                  // W1C
    wait_cycles(2);
    check_reg(regmodel.STATUS, 32'h0000_0000, 32'h0000_0004);   // cleared
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Rail : the resonance is parked just BEYOND the top of the DAC range, so the
//   sweep still sees light at its last point (and therefore succeeds) but the
//   fine loop can only ever say "hotter". The DAC must SATURATE at DAC_MAX -
//   never wrap to 0, which is the classic integrator-windup signature - and
//   RAIL_ERR must be set. `locked` must not rise: the loop is still moving.
class photonic_ring_tuner_rail_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_rail_vseq)
  function new(string name = "photonic_ring_tuner_rail_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    bit            got;

    regmodel.reset();
    `uvm_info("VSEQ_RAIL", $sformatf("resonance at %0.1f, DAC_MAX=%0d (%s)",
              m_cfg.m_ring_cfg.res_code, DAC_MAX,
              m_cfg.m_ring_cfg.convert2string()), UVM_LOW)

    enable_loop();
    wait_status_bit(1, 2 * deadline_cycles(), 1'b1,        // STATUS.RAIL_ERR
                    "the resonance is outside the DAC range", got);

    if (!got) begin
      read_reg(regmodel.STATUS, d);
      if (!d[1])
        `uvm_error("VSEQ_RAIL", $sformatf(
          "no RAIL_ERR after the loop drove past DAC_MAX (STATUS=0x%08h)", d))
    end

    // The DAC must be sitting AT the rail, not wrapped around to the bottom.
    read_reg(regmodel.DAC, d);
    if (d < (DAC_MAX - 2 * dither_eff()))
      `uvm_error("VSEQ_RAIL", $sformatf(
        "DAC=%0d is not saturated at DAC_MAX=%0d - did it wrap?", d, DAC_MAX))
    if (locked_now())
      `uvm_error("VSEQ_RAIL", "`locked` is high while the loop is against the rail")

    // Positive evidence that the loop ran, so "no lock" is not vacuous: the
    // ring is LIT here, so pd_q must have captured light as well.
    assert_loop_ran("rail (resonance beyond DAC_MAX)", 1'b1);

    // ---- sticky + W1C on RAIL_ERR ----
    disable_loop();
    wait_cycles(16);
    check_reg(regmodel.STATUS, 32'h0000_0002, 32'h0000_0002);   // still set
    write_reg(regmodel.STATUS, 32'h0000_0002);                  // W1C
    wait_cycles(2);
    check_reg(regmodel.STATUS, 32'h0000_0000, 32'h0000_0002);   // cleared
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// W1C-vs-HW-set RACE on RAIL_ERR (spec 3.5, SVA cover c_w1c_race_rail).
//
//   The race needs a W1C beat to STATUS.RAIL_ERR to complete on the SAME clock
//   that hardware re-asserts rail_err_q. The rail and dark vseqs both disable
//   the loop before clearing (deliberately, so their clear-check is
//   deterministic), which means hardware can never re-set the flag there and
//   the race is unreachable. This vseq exists purely to create it:
//
//     * the loop stays ENABLED and hard against the rail, so `rail_set`
//       (S_UPDATE with a clipped move) fires once per fine iteration and
//       rail_err_q is re-asserted for exactly one clock each time;
//     * SETTLE is shortened to 4, which shortens the fine iteration from ~69
//       clocks to ~13, so an APB W1C beat has roughly a 1-in-13 chance of
//       landing on the re-set clock instead of 1-in-69;
//     * THRESH is programmed to 0 so the loop can NEVER call the rail "at peak"
//       and stop pushing: at_peak requires !move_up, and with THRESH = 0 any
//       p_hi > p_lo keeps move_up asserted. (It also fills the cp_thresh zero
//       bin.) MINPOW is left at its reset value, so the false-lock guard is
//       untouched;
//     * the W1C writes are issued with a JITTERED gap so their phase relative
//       to the fine iteration walks instead of locking in step with it.
//
//   What this vseq CHECKS (spec 3.5, HW-set-wins): with the loop still railing,
//   RAIL_ERR must read back SET after a W1C -- either the hardware set won the
//   race outright, or the flag cleared and the next S_UPDATE re-set it. Either
//   way software cannot clear a condition that is still true. The same-clock
//   race itself is recorded by the bound SVA cover point, which this stimulus
//   makes reachable. Finally the loop is disabled and the flag IS cleared,
//   proving the bit is not simply stuck.
class photonic_ring_tuner_rail_w1c_race_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_rail_w1c_race_vseq)

  // Enough attempts that missing the ~1-in-13 coincidence on every one of them
  // is negligible ((1 - 1/13)^384 ~ 1e-13).
  rand int unsigned n_w1c;
  constraint c_n_w1c { n_w1c inside {[384:640]}; }

  function new(string name = "photonic_ring_tuner_rail_w1c_race_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    bit            got;
    int unsigned   i;
    int unsigned   n_readback;

    regmodel.reset();
    program_settle(4);                 // short fine iteration (see header)
    program_lock_cfg(16'h0000, 16'h0100);   // THRESH = 0, MINPOW at its default
    check_reg(regmodel.LOCK_CFG, 32'h0100_0000);

    `uvm_info("VSEQ_W1C_RACE", $sformatf(
      "railing the loop then hammering %0d W1C writes at STATUS.RAIL_ERR (%s)",
      n_w1c, m_cfg.m_ring_cfg.convert2string()), UVM_LOW)

    enable_loop();
    wait_status_bit(1, 2 * deadline_cycles(), 1'b1,        // STATUS.RAIL_ERR
                    "the resonance is outside the DAC range", got);
    if (!got)
      `uvm_error("VSEQ_W1C_RACE", $sformatf(
        "no RAIL_ERR within %0d cycles - cannot race a flag that never sets",
        2 * deadline_cycles()))

    // ---- the race window : loop ENABLED, railing, W1C hammered ----
    for (i = 0; i < n_w1c; i++) begin
      write_reg(regmodel.STATUS, 32'h0000_0002);        // W1C on RAIL_ERR
      if ((i % 64) == 63) begin
        // Wait comfortably past one fine iteration so the check is about
        // "hardware still owns this bit", not about catching the re-set edge.
        wait_cycles(96);
        read_reg(regmodel.STATUS, d);
        n_readback++;
        if (!d[1])
          `uvm_error("VSEQ_W1C_RACE", $sformatf(
            "RAIL_ERR read back CLEAR after W1C #%0d while the loop is still railed - software cleared a live hardware condition (STATUS=0x%08h)",
            i, d))
      end
      wait_cycles($urandom_range(0, 7));   // jitter the APB-vs-FSM phase
    end

    if (locked_now())
      `uvm_error("VSEQ_W1C_RACE", "`locked` is high while the loop is against the rail")
    assert_loop_ran("rail + W1C race", 1'b1);
    `uvm_info("VSEQ_W1C_RACE", $sformatf(
      "%0d W1C attempts, %0d readbacks, RAIL_ERR held set throughout", n_w1c,
      n_readback), UVM_LOW)

    // ---- and now it IS clearable, once hardware stops setting it ----
    disable_loop();
    wait_cycles(16);
    check_reg(regmodel.STATUS, 32'h0000_0002, 32'h0000_0002);   // still set
    write_reg(regmodel.STATUS, 32'h0000_0002);                  // W1C
    wait_cycles(2);
    check_reg(regmodel.STATUS, 32'h0000_0000, 32'h0000_0002);   // cleared
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Error : unmapped / unaligned accesses raise pslverr; RO register writes must
//   not (they are silently dropped, spec 2).
class photonic_ring_tuner_error_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_error_vseq)
  function new(string name = "photonic_ring_tuner_error_vseq"); super.new(name); endfunction

  task body();
    apb_seq_item it;
    regmodel.reset();

    // unmapped read (0x1C is just past PD)
    raw_access(APB_READ, 8'h1C, 32'h0, it);
    if (!it.slverr || (it.rdata !== 32'h0))
      `uvm_error("VSEQ_ERR", $sformatf("unmapped read: slverr=%0b rdata=0x%08h",
                 it.slverr, it.rdata))
    // unaligned read
    raw_access(APB_READ, 8'h06, 32'h0, it);
    if (!it.slverr)
      `uvm_error("VSEQ_ERR", "unaligned read did not raise pslverr")
    // unmapped write near the top of the decoded window
    raw_access(APB_WRITE, 8'hFC, 32'hDEAD_BEEF, it);
    if (!it.slverr)
      `uvm_error("VSEQ_ERR", "unmapped write did not raise pslverr")
    // legal write to RO DAC : NO pslverr, no effect
    raw_access(APB_WRITE, DAC_OFF, 32'h0000_0FFF, it);
    if (it.slverr)
      `uvm_error("VSEQ_ERR", "RO DAC write raised pslverr (should not)")
    raw_access(APB_READ, DAC_OFF, 32'h0, it);
    if (it.rdata !== 32'h0)
      `uvm_error("VSEQ_ERR", $sformatf("RO DAC changed: 0x%08h", it.rdata))
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Ratio sweep (COVERAGE, no verdict) : programs SETTLE as a randomized multiple
//   of the ring's thermal time constant so the spec-7.6 settle/tau cross fills
//   its {<1, 1-2, 2-4, >4} bins, and randomizes DITHER so the dither/linewidth
//   coverpoint fills too. The outcome is deliberately NOT asserted here - the
//   point of the cross is to SHOW which ratios acquire and which do not, so the
//   test runs with exp_outcome = RING_EXP_NONE.
class photonic_ring_tuner_ratio_vseq extends photonic_ring_tuner_base_vseq;
  `uvm_object_utils(photonic_ring_tuner_ratio_vseq)

  rand int unsigned ratio_sel;     // 0:<1  1:1-2  2:2-4  3:>4
  rand int unsigned dither_sel;

  constraint c_ratio  { ratio_sel  inside {[0:3]}; }
  constraint c_dither { dither_sel inside {[1:64]}; }

  function new(string name = "photonic_ring_tuner_ratio_vseq"); super.new(name); endfunction

  task body();
    real         k;
    int unsigned settle_val;
    uvm_reg_data_t d;

    regmodel.reset();
    case (ratio_sel)
      0:       k = 0.5;
      1:       k = 1.5;
      2:       k = 3.0;
      default: k = 8.0;
    endcase
    settle_val = $rtoi(k * m_cfg.m_ring_cfg.tau_cycles);
    if (settle_val > 128) settle_val = 128;      // keep the run time bounded

    program_settle(settle_val);
    program_step(dither_sel, 8'h20);
    `uvm_info("VSEQ_RATIO", $sformatf(
      "SETTLE=%0d tau=%0.1f ratio=%0.2f DITHER=%0d fwhm=%0.1f",
      settle_val, m_cfg.m_ring_cfg.tau_cycles,
      m_cfg.m_ring_cfg.settle_ratio(settle_val), dither_sel,
      m_cfg.m_ring_cfg.fwhm_code), UVM_LOW)

    enable_loop();
    wait_cycles(deadline_cycles());
    read_reg(regmodel.STATUS, d);
    `uvm_info("VSEQ_RATIO", $sformatf("outcome STATUS=0x%08h locked=%0b",
              d, locked_now()), UVM_LOW)
    disable_loop();
    wait_cycles(16);
  endtask
endclass

`endif // PHOTONIC_RING_TUNER_VSEQ_LIB_SVH
