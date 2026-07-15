// -----------------------------------------------------------------------------
// apb_gpio_test_lib.svh : test library for the apb_gpio UVM env.
//
//   apb_gpio_base_test builds:
//     * apb_config (ACTIVE), apb_gpio_reg_block (built + locked + reset),
//       apb_gpio_env_cfg (holds both + knobs), the env.
//   It fetches the tb-provided vifs (keys "apb_vif"/"gpio_vif" set globally by
//   the tb) and re-targets them to the exact child paths the env needs:
//     env.m_apb_agent  : "apb_vif"  (agent contract)
//     env.m_ref_model  : "vif"      (apb) + "pin_vif" (gpio)
//     env.m_gpio_agent : "gpio_vif"
//   Derived tests (one per vseq) override run_phase; start_vseq() wires the RAL
//   handle, the apb vif and the pin sequencer into the vseq, raises/drops the
//   objection, and leaves a drain window so trailing pin/irq events are scored.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_TEST_LIB_SVH
`define APB_GPIO_TEST_LIB_SVH

class apb_gpio_base_test extends uvm_test;
  `uvm_component_utils(apb_gpio_base_test)

  apb_gpio_env       env;
  apb_gpio_env_cfg   env_cfg;
  apb_config         apb_cfg;
  apb_gpio_reg_block reg_block;

  virtual apb_if     apb_vif;
  virtual gpio_if    gpio_vif;

  function new(string name = "apb_gpio_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // ---- vifs from the tb (set globally under these keys) ----
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", apb_vif))
      `uvm_fatal("TEST_NOVIF", "virtual apb_if 'apb_vif' not set by tb")
    if (!uvm_config_db#(virtual gpio_if)::get(this, "", "gpio_vif", gpio_vif))
      `uvm_fatal("TEST_NOVIF", "virtual gpio_if 'gpio_vif' not set by tb")

    // ---- APB agent config ----
    apb_cfg = apb_config::type_id::create("apb_cfg");
    apb_cfg.is_active       = UVM_ACTIVE;
    apb_cfg.coverage_enable = 1'b1;

    // ---- RAL model ----
    reg_block = apb_gpio_reg_block::type_id::create("reg_block");
    reg_block.build();         // create regs + map, then lock_model()
    reg_block.reset();         // mirror -> reset

    // ---- env config ----
    env_cfg = apb_gpio_env_cfg::type_id::create("env_cfg");
    env_cfg.m_apb_cfg     = apb_cfg;
    env_cfg.reg_block     = reg_block;
    env_cfg.en_scoreboard = 1'b1;
    env_cfg.en_coverage   = 1'b1;
    uvm_config_db#(apb_gpio_env_cfg)::set(this, "env", "env_cfg", env_cfg);

    // ---- build env ----
    env = apb_gpio_env::type_id::create("env", this);

    // ---- distribute vifs to the exact child paths ----
    uvm_config_db#(virtual apb_if)::set(this, "env.m_apb_agent", "apb_vif", apb_vif);
    uvm_config_db#(virtual apb_if)::set(this, "env.m_ref_model",  "vif",     apb_vif);
    uvm_config_db#(virtual gpio_if)::set(this, "env.m_ref_model", "pin_vif", gpio_vif);
    uvm_config_db#(virtual gpio_if)::set(this, "env.m_gpio_agent", "gpio_vif", gpio_vif);
  endfunction

  // Wire + run a vseq with objection + drain.
  task start_vseq(apb_gpio_base_vseq seq, uvm_phase phase);
    seq.regmodel = reg_block;
    seq.vif      = apb_vif;
    seq.pin_seqr = env.m_gpio_agent.seqr;
    // wait for reset release before stimulating
    wait (apb_vif.rst_n === 1'b1);
    repeat (2) @(posedge apb_vif.clk);
    phase.raise_objection(this, "vseq");
    seq.start(env.m_apb_agent.seqr);
    #200ns;    // drain: let trailing pin/irq events reach the scoreboard
    phase.drop_objection(this, "vseq");
  endtask

  // Default: smoke.
  task run_phase(uvm_phase phase);
    apb_gpio_smoke_vseq s = apb_gpio_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask

endclass

// ---------------------------------------------------------------------------
class apb_gpio_smoke_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_smoke_test)
  function new(string name = "apb_gpio_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_smoke_vseq s = apb_gpio_smoke_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_output_drive_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_output_drive_test)
  function new(string name = "apb_gpio_output_drive_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_output_drive_vseq s = apb_gpio_output_drive_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_input_capture_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_input_capture_test)
  function new(string name = "apb_gpio_input_capture_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_input_capture_vseq s = apb_gpio_input_capture_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "input_capture vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_interrupt_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_interrupt_test)
  function new(string name = "apb_gpio_interrupt_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_interrupt_vseq s = apb_gpio_interrupt_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_w1c_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_w1c_test)
  function new(string name = "apb_gpio_w1c_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_w1c_vseq s = apb_gpio_w1c_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_error_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_error_test)
  function new(string name = "apb_gpio_error_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_error_vseq s = apb_gpio_error_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_reg_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_reg_test)
  function new(string name = "apb_gpio_reg_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_reg_vseq s = apb_gpio_reg_vseq::type_id::create("s");
    start_vseq(s, phase);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_gpio_rand_test extends apb_gpio_base_test;
  `uvm_component_utils(apb_gpio_rand_test)
  function new(string name = "apb_gpio_rand_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    apb_gpio_rand_vseq s = apb_gpio_rand_vseq::type_id::create("s");
    if (!s.randomize())
      `uvm_error("TEST", "rand vseq randomize failed")
    start_vseq(s, phase);
  endtask
endclass

`endif // APB_GPIO_TEST_LIB_SVH
