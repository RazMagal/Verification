// -----------------------------------------------------------------------------
// apb_timer_test_lib.svh : test library for the apb_timer UVM env.
//
//   apb_timer_base_test builds:
//     * apb_config (ACTIVE), apb_timer_reg_block (built + locked + reset),
//       apb_timer_env_cfg (holds both + knobs), the env.
//   It fetches the tb-provided vifs (keys "apb_vif"/"irq_vif" set globally by
//   the tb) and re-targets them to the exact child paths the env needs:
//     env.m_apb_agent : "apb_vif"  (agent contract)
//     env.m_ref_model : "vif"
//     env.m_irq_agent : "irq_vif"
//   Derived tests (one per vseq) override run_phase; start_vseq() wires the RAL
//   handle + vif into the vseq, raises/drops the objection, and leaves a drain
//   window so trailing IRQ edges are scored.
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_TEST_LIB_SVH
`define APB_TIMER_TEST_LIB_SVH

class apb_timer_base_test extends uvm_test;
  `uvm_component_utils(apb_timer_base_test)

  apb_timer_env        env;
  apb_timer_env_cfg    env_cfg;
  apb_config           apb_cfg;
  apb_timer_reg_block  reg_block;

  virtual apb_if       apb_vif;
  virtual timer_irq_if irq_vif;

  function new(string name = "apb_timer_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // ---- vifs from the tb (set globally under these keys) ----
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", apb_vif))
      `uvm_fatal("TEST_NOVIF", "virtual apb_if 'apb_vif' not set by tb")
    if (!uvm_config_db#(virtual timer_irq_if)::get(this, "", "irq_vif", irq_vif))
      `uvm_fatal("TEST_NOVIF", "virtual timer_irq_if 'irq_vif' not set by tb")

    // ---- APB agent config ----
    apb_cfg = apb_config::type_id::create("apb_cfg");
    apb_cfg.is_active       = UVM_ACTIVE;
    apb_cfg.coverage_enable = 1'b1;

    // ---- RAL model ----
    reg_block = apb_timer_reg_block::type_id::create("reg_block");
    reg_block.build();         // create regs + map, then lock_model()
    reg_block.reset();         // mirror -> reset

    // ---- env config ----
    env_cfg = apb_timer_env_cfg::type_id::create("env_cfg");
    env_cfg.m_apb_cfg     = apb_cfg;
    env_cfg.reg_block     = reg_block;
    env_cfg.en_scoreboard = 1'b1;
    env_cfg.en_coverage   = 1'b1;
    uvm_config_db#(apb_timer_env_cfg)::set(this, "env", "env_cfg", env_cfg);

    // ---- build env ----
    env = apb_timer_env::type_id::create("env", this);

    // ---- distribute vifs to the exact child paths ----
    uvm_config_db#(virtual apb_if)::set(this, "env.m_apb_agent", "apb_vif", apb_vif);
    uvm_config_db#(virtual apb_if)::set(this, "env.m_ref_model",  "vif",    apb_vif);
    uvm_config_db#(virtual timer_irq_if)::set(this, "env.m_irq_agent", "irq_vif", irq_vif);
  endfunction

  // Wire + run a vseq with objection + drain.
  task start_vseq(apb_timer_base_vseq seq, uvm_phase phase);
    seq.regmodel = reg_block;
    seq.vif      = apb_vif;
    // wait for reset release before stimulating
    wait (apb_vif.rst_n === 1'b1);
    repeat (2) @(posedge apb_vif.clk);
    phase.raise_objection(this, "vseq");
    seq.start(env.m_apb_agent.seqr);
    #200ns;    // drain: let trailing IRQ edges reach the scoreboard
    phase.drop_objection(this, "vseq");
  endtask

  // Default: smoke.
  task run_phase(uvm_phase phase);
    apb_timer_smoke_vseq s = apb_timer_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask

endclass

// ---------------------------------------------------------------------------
class apb_timer_smoke_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_smoke_test)
  function new(string name = "apb_timer_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_smoke_vseq s = apb_timer_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_oneshot_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_oneshot_test)
  function new(string name = "apb_timer_oneshot_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_oneshot_vseq s = apb_timer_oneshot_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "oneshot vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_periodic_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_periodic_test)
  function new(string name = "apb_timer_periodic_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_periodic_vseq s = apb_timer_periodic_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "periodic vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_prescale_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_prescale_test)
  function new(string name = "apb_timer_prescale_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_prescale_vseq s = apb_timer_prescale_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_w1c_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_w1c_test)
  function new(string name = "apb_timer_w1c_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_w1c_vseq s = apb_timer_w1c_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_irq_mask_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_irq_mask_test)
  function new(string name = "apb_timer_irq_mask_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_irq_mask_vseq s = apb_timer_irq_mask_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_error_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_error_test)
  function new(string name = "apb_timer_error_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_error_vseq s = apb_timer_error_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_reg_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_reg_test)
  function new(string name = "apb_timer_reg_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_reg_hw_reset_vseq s = apb_timer_reg_hw_reset_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_timer_rand_test extends apb_timer_base_test;
  `uvm_component_utils(apb_timer_rand_test)
  function new(string name = "apb_timer_rand_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_timer_rand_vseq s = apb_timer_rand_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "rand vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

`endif // APB_TIMER_TEST_LIB_SVH
