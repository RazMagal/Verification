// -----------------------------------------------------------------------------
// photonic_ring_tuner_test_lib.svh : test library for the tuner UVM env.
//
//   photonic_ring_tuner_base_test builds:
//     * apb_config (ACTIVE), photonic_ring_tuner_reg_block (built + locked +
//       reset), a randomized ring_cfg, photonic_ring_tuner_env_cfg (holds them
//       plus the expected optical outcome), and the env.
//   It fetches the tb-provided vifs (keys "apb_vif" / "ring_vif", set globally by
//   the tb) and re-targets them to the exact child paths the env needs:
//     env.m_apb_agent  : "apb_vif"  (agent contract)
//     env.m_scoreboard : "ring_vif"
//
//   A derived test customises the run by overriding THREE things:
//     ring_mode()   - which physical regime to randomize the ring into
//     exp_outcome() - what the scoreboard must prove about the run
//     run_phase()   - which vseq to start
//   The ring is randomized in build_phase (so it is reproducible from the UVM
//   seed) and applied to ring_if in start_of_simulation_phase, i.e. BEFORE reset
//   is released and long before any stimulus.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_TEST_LIB_SVH
`define PHOTONIC_RING_TUNER_TEST_LIB_SVH

class photonic_ring_tuner_base_test extends uvm_test;
  `uvm_component_utils(photonic_ring_tuner_base_test)

  photonic_ring_tuner_env       env;
  photonic_ring_tuner_env_cfg   env_cfg;
  apb_config                    apb_cfg;
  photonic_ring_tuner_reg_block reg_block;
  ring_cfg                      m_ring_cfg;

  virtual apb_if                apb_vif;
  virtual ring_if               ring_vif;

  function new(string name = "photonic_ring_tuner_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---- knobs a derived test overrides --------------------------------------
  virtual function ring_mode_e ring_mode();
    return RING_MODE_DEFAULT;
  endfunction

  virtual function ring_exp_e exp_outcome();
    return RING_EXP_NONE;
  endfunction

  // WHICH IMPLEMENTATION of the optical physics evaluates that regime. Every
  // existing test leaves this at RING_MODEL_SV, so the default flow is
  // unchanged and needs no C, no +define+RING_DPI and no shared library --
  // which is what keeps this suite runnable on EDA Playground. Overridden only
  // by photonic_ring_tuner_dpi_equiv_test, and by +RING_MODEL on any test.
  virtual function ring_model_e ring_model_mode();
    return RING_MODEL_SV;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // ---- vifs from the tb (set globally under these keys) ----
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", apb_vif))
      `uvm_fatal("TEST_NOVIF", "virtual apb_if 'apb_vif' not set by tb")
    if (!uvm_config_db#(virtual ring_if)::get(this, "", "ring_vif", ring_vif))
      `uvm_fatal("TEST_NOVIF", "virtual ring_if 'ring_vif' not set by tb")

    // ---- APB agent config ----
    apb_cfg = apb_config::type_id::create("apb_cfg");
    apb_cfg.is_active       = UVM_ACTIVE;
    apb_cfg.coverage_enable = 1'b1;

    // ---- RAL model ----
    reg_block = photonic_ring_tuner_reg_block::type_id::create("reg_block");
    reg_block.build();         // create regs + map, then lock_model()
    reg_block.reset();         // mirror -> reset

    // ---- the optical stimulus : randomized here, so it is reproducible from
    //      the UVM seed and printed in the log before anything runs ----
    m_ring_cfg            = ring_cfg::type_id::create("m_ring_cfg");
    m_ring_cfg.mode       = ring_mode();
    m_ring_cfg.model_mode = ring_model_mode();
    if (!m_ring_cfg.randomize())
      `uvm_fatal("TEST_RAND", $sformatf("ring_cfg randomize failed for mode %s",
                 ring_mode().name()))

    // ---- env config ----
    env_cfg = photonic_ring_tuner_env_cfg::type_id::create("env_cfg");
    env_cfg.m_apb_cfg     = apb_cfg;
    env_cfg.reg_block     = reg_block;
    env_cfg.m_ring_cfg    = m_ring_cfg;
    env_cfg.exp_outcome   = exp_outcome();
    env_cfg.en_scoreboard = 1'b1;
    env_cfg.en_coverage   = 1'b1;
    uvm_config_db#(photonic_ring_tuner_env_cfg)::set(this, "env", "env_cfg", env_cfg);

    // ---- build env ----
    env = photonic_ring_tuner_env::type_id::create("env", this);

    // ---- distribute vifs to the exact child paths ----
    uvm_config_db#(virtual apb_if)::set(this, "env.m_apb_agent", "apb_vif", apb_vif);
    uvm_config_db#(virtual ring_if)::set(this, "env.m_scoreboard", "ring_vif", ring_vif);
  endfunction

  // Put the physics onto the model before reset is released.
  function void start_of_simulation_phase(uvm_phase phase);
    super.start_of_simulation_phase(phase);
    // apply() also RESOLVES the model backend (+RING_MODEL beats the test's
    // choice) and writes it onto ring_if, so the line below reports what will
    // actually run rather than what was requested.
    m_ring_cfg.apply(ring_vif);
    `uvm_info("TEST_RING", $sformatf("ring under test -> %s | expecting %s",
              m_ring_cfg.convert2string(), exp_outcome().name()), UVM_LOW)
`ifdef RING_DPI
    `uvm_info("TEST_DPI", $sformatf(
      "DPI layer compiled in (+define+RING_DPI); C model reports version \"%s\"",
      photonics_dpi_pkg::ring_dpi_version()), UVM_LOW)
`endif
  endfunction

  // Wire + run a vseq with objection + drain.
  task start_vseq(photonic_ring_tuner_base_vseq seq, uvm_phase phase);
    seq.regmodel = reg_block;
    seq.vif      = apb_vif;
    seq.ring_vif = ring_vif;
    seq.m_cfg    = env_cfg;
    // wait for reset release before stimulating
    wait (apb_vif.rst_n === 1'b1);
    repeat (2) @(posedge apb_vif.clk);
    phase.raise_objection(this, "vseq");
    seq.start(env.m_apb_agent.seqr);
    #500ns;    // drain: let the last optical cycles reach the scoreboard
    phase.drop_objection(this, "vseq");
  endtask

  // Default: smoke.
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_smoke_vseq s =
        photonic_ring_tuner_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask

endclass

// ---------------------------------------------------------------------------
// Smoke : register reset values + RW / RO / W1C behaviour, loop never enabled.
class photonic_ring_tuner_smoke_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_smoke_test)
  function new(string name = "photonic_ring_tuner_smoke_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_smoke_vseq s =
        photonic_ring_tuner_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// RAL : uvm_reg_hw_reset_seq + uvm_reg_bit_bash_seq (STATUS / DAC / PD excluded).
class photonic_ring_tuner_reg_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_reg_test)
  function new(string name = "photonic_ring_tuner_reg_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_reg_vseq s =
        photonic_ring_tuner_reg_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// Lock from cold on a randomized, reachable resonance : the positive test.
class photonic_ring_tuner_lock_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_lock_test)
  function new(string name = "photonic_ring_tuner_lock_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_LOCKABLE; endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_LOCK;    endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_lock_vseq s =
        photonic_ring_tuner_lock_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// Lock LOSS (directed) : acquire, then break the lock on purpose (the fibre goes
//   dark with the loop still enabled) and check the loop responds correctly --
//   `locked` deasserts, ACTIVE stays high, no error flag is invented, and the
//   loop re-acquires when the light returns. This is the only test that fills
//   cg_acq.cp_outcome.lost_lock (spec 7.6) and the SVA's lock-lost cover point;
//   in lock_test a lost lock is a failure, so the bin was otherwise unfillable.
class photonic_ring_tuner_lock_loss_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_lock_loss_test)
  function new(string name = "photonic_ring_tuner_lock_loss_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_LOCKABLE;      endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_LOCK_THEN_LOSS; endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_lock_loss_vseq s =
        photonic_ring_tuner_lock_loss_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// SETTLE < tau : the headline negative test. The loop samples the photodiode
//   before the ring has thermally settled, so it must NOT acquire.
class photonic_ring_tuner_settle_short_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_settle_short_test)
  function new(string name = "photonic_ring_tuner_settle_short_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_SLOW_THERMAL; endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_NO_LOCK;     endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_settle_short_vseq s =
        photonic_ring_tuner_settle_short_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "settle_short vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// Dark fibre : laser off => SWEEP_ERR, and `locked` never rises (spec 3.4).
class photonic_ring_tuner_dark_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_dark_test)
  function new(string name = "photonic_ring_tuner_dark_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_DARK;       endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_SWEEP_ERR; endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_dark_vseq s =
        photonic_ring_tuner_dark_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// Rail : resonance beyond DAC_MAX => RAIL_ERR, saturation without wraparound.
class photonic_ring_tuner_rail_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_rail_test)
  function new(string name = "photonic_ring_tuner_rail_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_RAIL;      endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_RAIL_ERR; endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_rail_vseq s =
        photonic_ring_tuner_rail_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// Directed W1C-vs-HW-set race on RAIL_ERR (spec 3.5). Same rail regime and the
// same scoreboard verdict as the rail test, but the loop is left ENABLED and
// railing while software hammers W1C, which is the only way the bound SVA cover
// point c_w1c_race_rail can ever be hit.
class photonic_ring_tuner_rail_w1c_race_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_rail_w1c_race_test)
  function new(string name = "photonic_ring_tuner_rail_w1c_race_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_RAIL;      endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_RAIL_ERR; endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_rail_w1c_race_vseq s =
        photonic_ring_tuner_rail_w1c_race_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "rail_w1c_race vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// APB error behaviour : unmapped / unaligned => pslverr; RO writes dropped.
class photonic_ring_tuner_error_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_error_test)
  function new(string name = "photonic_ring_tuner_error_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_error_vseq s =
        photonic_ring_tuner_error_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// Ratio sweep : fills the settle/tau x outcome cross. No optical verdict - the
//   point is to SHOW which ratios acquire, so exp_outcome stays RING_EXP_NONE.
class photonic_ring_tuner_ratio_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_ratio_test)
  function new(string name = "photonic_ring_tuner_ratio_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  virtual function ring_mode_e ring_mode(); return RING_MODE_LOCKABLE; endfunction
  virtual function ring_exp_e  exp_outcome(); return RING_EXP_NONE;    endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_ratio_vseq s =
        photonic_ring_tuner_ratio_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "ratio vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// SV vs DPI-C MODEL EQUIVALENCE : the deliverable of the DPI layer.
//
//   Runs a full acquisition (plus a directed corner walk) with the optical model
//   in RING_MODEL_COMPARE, i.e. with the SystemVerilog reference model and the C
//   model behind common/dpi evaluated in LOCKSTEP on identical inputs -- same
//   dac_code, same clamped tau/fwhm, and the same $urandom noise sample, drawn
//   in SystemVerilog and passed into photonics_ring_step so the run stays
//   reproducible from its seed and the comparison stays meaningful. Both are
//   IEEE-754 doubles doing the same operations in the same order, so the
//   quantized adc_code must agree EXACTLY; ring_model reports any disagreement
//   as a RING_DPI_EQUIV uvm_error naming the cycle, the inputs and both outputs.
//
//   REQUIRES +define+RING_DPI. Without it there is no C model to compare
//   against, and ring_cfg::resolve_model_mode() ends the run with a uvm_fatal
//   naming the missing define -- deliberately, because an "equivalence test"
//   that quietly fell back to comparing the SV model with itself would be the
//   most expensive kind of green run there is.
//
//     make -C ip/photonic_ring_tuner/sim questa_dpi   # or vcs_dpi / xrun_dpi
//     make -C ip/photonic_ring_tuner/sim regress_dpi  # the equivalence x seeds
class photonic_ring_tuner_dpi_equiv_test extends photonic_ring_tuner_base_test;
  `uvm_component_utils(photonic_ring_tuner_dpi_equiv_test)
  function new(string name = "photonic_ring_tuner_dpi_equiv_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  // A LOCKABLE ring, so the equivalence is measured on a loop that really
  // acquires: an equivalence run over a dead ring would compare two models that
  // both sat still.
  virtual function ring_mode_e  ring_mode();       return RING_MODE_LOCKABLE;  endfunction
  virtual function ring_exp_e   exp_outcome();     return RING_EXP_LOCK;       endfunction
  virtual function ring_model_e ring_model_mode(); return RING_MODEL_COMPARE;  endfunction
  task run_phase(uvm_phase phase);
    photonic_ring_tuner_dpi_equiv_vseq s =
        photonic_ring_tuner_dpi_equiv_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

`endif // PHOTONIC_RING_TUNER_TEST_LIB_SVH
