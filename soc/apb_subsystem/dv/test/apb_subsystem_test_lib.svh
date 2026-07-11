// -----------------------------------------------------------------------------
// apb_subsystem_test_lib.svh : test library for the apb_subsystem UVM env.
//
//   apb_subsystem_base_test builds:
//     * top apb_config (ACTIVE) + two PASSIVE apb_configs for the timer sub-agents
//     * the hierarchical apb_subsystem_reg_block (build + lock + reset)
//     * apb_subsystem_env_cfg (all of the above + knobs)
//     * the env
//   then distributes the tb-provided vifs (fetched under the global keys
//   vif_top / vif_t0 / vif_t1 / vif_irq0 / vif_irq1) to the EXACT child paths the
//   reused agents / ref-models / irq-agents expect:
//     top    : env.m_top_agent               "apb_vif"
//     timer0 : env.m_timer_env0.m_apb_agent  "apb_vif"
//              env.m_timer_env0.m_ref_model   "vif"
//              env.m_timer_env0.m_irq_agent   "irq_vif"
//     timer1 : env.m_timer_env1.*             (same shape, t1_if / irq1)
//
//   start_vseq() wires the RAL handle + top vif into a vseq, waits out reset,
//   raises/drops the objection and leaves a drain window so trailing IRQ edges
//   reach the per-timer scoreboards.
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_TEST_LIB_SVH
`define APB_SUBSYSTEM_TEST_LIB_SVH

class apb_subsystem_base_test extends uvm_test;
  `uvm_component_utils(apb_subsystem_base_test)

  apb_subsystem_env       env;
  apb_subsystem_env_cfg   env_cfg;
  apb_subsystem_reg_block reg_block;

  apb_config              top_cfg;
  apb_config              t0_cfg;
  apb_config              t1_cfg;

  // vifs from the tb (five distinct interface instances)
  virtual apb_if          vif_top;
  virtual apb_if          vif_t0;
  virtual apb_if          vif_t1;
  virtual timer_irq_if    vif_irq0;
  virtual timer_irq_if    vif_irq1;

  function new(string name = "apb_subsystem_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // ---- vifs from the tb (set globally under these keys) ----
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif_top", vif_top))
      `uvm_fatal("TEST_NOVIF", "virtual apb_if 'vif_top' not set by tb")
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif_t0", vif_t0))
      `uvm_fatal("TEST_NOVIF", "virtual apb_if 'vif_t0' not set by tb")
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif_t1", vif_t1))
      `uvm_fatal("TEST_NOVIF", "virtual apb_if 'vif_t1' not set by tb")
    if (!uvm_config_db#(virtual timer_irq_if)::get(this, "", "vif_irq0", vif_irq0))
      `uvm_fatal("TEST_NOVIF", "virtual timer_irq_if 'vif_irq0' not set by tb")
    if (!uvm_config_db#(virtual timer_irq_if)::get(this, "", "vif_irq1", vif_irq1))
      `uvm_fatal("TEST_NOVIF", "virtual timer_irq_if 'vif_irq1' not set by tb")

    // ---- agent configs : one ACTIVE upstream, two PASSIVE per-timer ----
    top_cfg = apb_config::type_id::create("top_cfg");
    top_cfg.is_active       = UVM_ACTIVE;
    top_cfg.coverage_enable = 1'b1;

    t0_cfg = apb_config::type_id::create("t0_cfg");
    t0_cfg.is_active       = UVM_PASSIVE;
    t0_cfg.coverage_enable = 1'b1;

    t1_cfg = apb_config::type_id::create("t1_cfg");
    t1_cfg.is_active       = UVM_PASSIVE;
    t1_cfg.coverage_enable = 1'b1;

    // ---- hierarchical RAL model ----
    reg_block = apb_subsystem_reg_block::type_id::create("reg_block");
    reg_block.build();     // create timers/mem + submaps, lock_model()
    reg_block.reset();     // mirror -> reset (recurses into both timer blocks)

    // ---- env config ----
    env_cfg = apb_subsystem_env_cfg::type_id::create("env_cfg");
    env_cfg.m_top_cfg      = top_cfg;
    env_cfg.m_timer_cfg[0] = t0_cfg;
    env_cfg.m_timer_cfg[1] = t1_cfg;
    env_cfg.reg_block      = reg_block;
    env_cfg.en_scoreboard  = 1'b1;
    env_cfg.en_coverage    = 1'b1;
    env_cfg.en_timer_env   = 1'b1;
    uvm_config_db#(apb_subsystem_env_cfg)::set(this, "env", "env_cfg", env_cfg);

    // ---- build env ----
    env = apb_subsystem_env::type_id::create("env", this);

    // ---- distribute vifs to the exact reused-child paths ----
    // top active agent -> upstream u_apb_if
    uvm_config_db#(virtual apb_if)::set(this, "env.m_top_agent", "apb_vif", vif_top);
    // timer0 passive agent + ref model -> internal t0_if ; irq agent -> irq0
    uvm_config_db#(virtual apb_if)::set(this, "env.m_timer_env0.m_apb_agent",
                                        "apb_vif", vif_t0);
    uvm_config_db#(virtual apb_if)::set(this, "env.m_timer_env0.m_ref_model",
                                        "vif", vif_t0);
    uvm_config_db#(virtual timer_irq_if)::set(this, "env.m_timer_env0.m_irq_agent",
                                              "irq_vif", vif_irq0);
    // timer1 passive agent + ref model -> internal t1_if ; irq agent -> irq1
    uvm_config_db#(virtual apb_if)::set(this, "env.m_timer_env1.m_apb_agent",
                                        "apb_vif", vif_t1);
    uvm_config_db#(virtual apb_if)::set(this, "env.m_timer_env1.m_ref_model",
                                        "vif", vif_t1);
    uvm_config_db#(virtual timer_irq_if)::set(this, "env.m_timer_env1.m_irq_agent",
                                              "irq_vif", vif_irq1);
  endfunction

  // Wire + run a vseq with objection + drain.
  task start_vseq(apb_subsystem_base_vseq seq, uvm_phase phase);
    seq.regmodel = reg_block;
    seq.vif      = vif_top;
    wait (vif_top.rst_n === 1'b1);          // reset release
    repeat (2) @(posedge vif_top.clk);
    phase.raise_objection(this, "vseq");
    seq.start(env.m_vseqr);
    #300ns;                                  // drain trailing IRQ edges
    phase.drop_objection(this, "vseq");
  endtask

  // Default : smoke.
  task run_phase(uvm_phase phase);
    apb_subsystem_smoke_vseq s = apb_subsystem_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask

endclass

// ---------------------------------------------------------------------------
class apb_subsystem_smoke_test extends apb_subsystem_base_test;
  `uvm_component_utils(apb_subsystem_smoke_test)
  function new(string name = "apb_subsystem_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_subsystem_smoke_vseq s = apb_subsystem_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
// FLAGSHIP : concurrent independent timers.
class apb_subsystem_concurrent_timers_test extends apb_subsystem_base_test;
  `uvm_component_utils(apb_subsystem_concurrent_timers_test)
  function new(string name = "apb_subsystem_concurrent_timers_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_subsystem_concurrent_timers_vseq s =
        apb_subsystem_concurrent_timers_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_subsystem_mem_test extends apb_subsystem_base_test;
  `uvm_component_utils(apb_subsystem_mem_test)
  function new(string name = "apb_subsystem_mem_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_subsystem_mem_vseq s = apb_subsystem_mem_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_subsystem_decode_error_test extends apb_subsystem_base_test;
  `uvm_component_utils(apb_subsystem_decode_error_test)
  function new(string name = "apb_subsystem_decode_error_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_subsystem_decode_error_vseq s =
        apb_subsystem_decode_error_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_subsystem_rand_test extends apb_subsystem_base_test;
  `uvm_component_utils(apb_subsystem_rand_test)
  function new(string name = "apb_subsystem_rand_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_subsystem_rand_vseq s = apb_subsystem_rand_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "rand vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

`endif // APB_SUBSYSTEM_TEST_LIB_SVH
