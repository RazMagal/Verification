// -----------------------------------------------------------------------------
// apb_gpio_scoreboard.svh : reference-model scoreboard for apb_gpio.
//
//   Two paired streams, each via its own uvm_tlm_analysis_fifo so the single
//   write() collision is avoided and pairing is strictly in-order:
//     APB : expected (apb_gpio_ref_model) vs actual (apb_monitor)
//     PIN : expected (apb_gpio_ref_model) vs actual (gpio_monitor)
//
//   Checks (ALL EXACT, no tolerance -- the reference model is cycle-exact):
//     * APB READ  : dir/addr/slverr exact; rdata exact for every register,
//                   including the volatile RO DATA_IN readback (= din_sync) and
//                   unmapped (rdata==0, slverr==1).
//     * APB WRITE : dir/addr/slverr exact (unmapped -> slverr; legal incl. RO
//                   DATA_IN -> no slverr).
//     * PIN       : gpio_out / gpio_oe / irq exact and in-order; the posedge
//                   cycle stamp must match EXACTLY (a 1-cycle-late/early output
//                   or irq is a bug).
//
//   check_phase: reports pass/fail counts, drains any UNMATCHED items (a leftover
//   in either fifo is an error), and FAILS if nothing was checked.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_SCOREBOARD_SVH
`define APB_GPIO_SCOREBOARD_SVH

class apb_gpio_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(apb_gpio_scoreboard)

  // APB streams.
  uvm_tlm_analysis_fifo #(apb_seq_item)  apb_exp_fifo;
  uvm_tlm_analysis_fifo #(apb_seq_item)  apb_act_fifo;
  // PIN streams.
  uvm_tlm_analysis_fifo #(gpio_mon_item) pin_exp_fifo;
  uvm_tlm_analysis_fifo #(gpio_mon_item) pin_act_fifo;

  int unsigned apb_checks, apb_pass, apb_fail;
  int unsigned pin_checks, pin_pass, pin_fail;

  function new(string name = "apb_gpio_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    apb_exp_fifo = new("apb_exp_fifo", this);
    apb_act_fifo = new("apb_act_fifo", this);
    pin_exp_fifo = new("pin_exp_fifo", this);
    pin_act_fifo = new("pin_act_fifo", this);
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    fork
      check_apb();
      check_pin();
    join
  endtask

  // ---- APB expected vs actual (in-order) ----
  task check_apb();
    apb_seq_item exp, act;
    forever begin
      apb_exp_fifo.get(exp);
      apb_act_fifo.get(act);
      apb_checks++;
      compare_apb(exp, act);
    end
  endtask

  function void compare_apb(apb_seq_item exp, apb_seq_item act);
    bit err = 1'b0;
    if (exp.dir !== act.dir) begin
      err = 1'b1;
      `uvm_error("SCB_APB_DIR", $sformatf("dir mismatch exp=%s act=%s",
                 exp.dir.name(), act.dir.name()))
    end
    if (exp.addr !== act.addr) begin
      err = 1'b1;
      `uvm_error("SCB_APB_ADDR", $sformatf("addr mismatch exp=0x%02h act=0x%02h",
                 exp.addr, act.addr))
    end
    if (exp.slverr !== act.slverr) begin
      err = 1'b1;
      `uvm_error("SCB_APB_SLVERR", $sformatf(
                 "slverr mismatch @0x%02h exp=%0b act=%0b",
                 act.addr, exp.slverr, act.slverr))
    end
    if (act.dir == APB_READ) begin
      // Cycle-exact model: EVERY read -- DATA_IN (din_sync) included -- matches
      // exactly. A tolerance here would only mask a genuine synchronizer or
      // register-readback bug, which is precisely what this env exists to catch.
      if (exp.rdata !== act.rdata) begin
        err = 1'b1;
        `uvm_error("SCB_APB_RDATA", $sformatf(
                   "rdata mismatch @0x%02h exp=0x%08h act=0x%08h",
                   act.addr, exp.rdata, act.rdata))
      end
    end
    if (err) apb_fail++;
    else begin
      apb_pass++;
      `uvm_info("SCB_APB_OK", $sformatf("MATCH %s", act.convert2string()), UVM_HIGH)
    end
  endfunction

  // ---- PIN expected vs actual (in-order) ----
  task check_pin();
    gpio_mon_item exp, act;
    forever begin
      pin_exp_fifo.get(exp);
      pin_act_fifo.get(act);
      pin_checks++;
      compare_pin(exp, act);
    end
  endtask

  function void compare_pin(gpio_mon_item exp, gpio_mon_item act);
    bit err = 1'b0;
    int unsigned dcyc;
    if (exp.gpio_out !== act.gpio_out) begin
      err = 1'b1;
      `uvm_error("SCB_PIN_OUT", $sformatf("gpio_out mismatch exp=0x%08h act=0x%08h",
                 exp.gpio_out, act.gpio_out))
    end
    if (exp.gpio_oe !== act.gpio_oe) begin
      err = 1'b1;
      `uvm_error("SCB_PIN_OE", $sformatf("gpio_oe mismatch exp=0x%08h act=0x%08h",
                 exp.gpio_oe, act.gpio_oe))
    end
    if (exp.irq !== act.irq) begin
      err = 1'b1;
      `uvm_error("SCB_PIN_IRQ", $sformatf("irq mismatch exp=%0b act=%0b",
                 exp.irq, act.irq))
    end
    if (!err) begin
      dcyc = (exp.cyc > act.cyc) ? (exp.cyc - act.cyc) : (act.cyc - exp.cyc);
      // Outputs/irq are cycle-aligned in the exact model (dcyc==0 on good HW).
      if (dcyc > 0) begin
        err = 1'b1;
        `uvm_error("SCB_PIN_TIME", $sformatf(
                   "pin-output cycle off by %0d (exp cyc=%0d act cyc=%0d) %s",
                   dcyc, exp.cyc, act.cyc, act.convert2string()))
      end
      else begin
        `uvm_info("SCB_PIN_OK", $sformatf("PIN MATCH %s", act.convert2string()),
                  UVM_MEDIUM)
      end
    end
    if (err) pin_fail++;
    else     pin_pass++;
  endfunction

  // ---- drain leftovers + report ----
  function void check_phase(uvm_phase phase);
    apb_seq_item  a;
    gpio_mon_item p;
    super.check_phase(phase);

    while (apb_exp_fifo.try_get(a)) begin
      apb_fail++;
      `uvm_error("SCB_APB_UNMATCHED_EXP",
                 $sformatf("expected APB with no actual: %s", a.convert2string()))
    end
    while (apb_act_fifo.try_get(a)) begin
      apb_fail++;
      `uvm_error("SCB_APB_UNMATCHED_ACT",
                 $sformatf("actual APB with no expected: %s", a.convert2string()))
    end
    while (pin_exp_fifo.try_get(p)) begin
      pin_fail++;
      `uvm_error("SCB_PIN_UNMATCHED_EXP",
                 $sformatf("expected PIN with no actual: %s", p.convert2string()))
    end
    while (pin_act_fifo.try_get(p)) begin
      pin_fail++;
      `uvm_error("SCB_PIN_UNMATCHED_ACT",
                 $sformatf("actual PIN with no expected: %s", p.convert2string()))
    end

    `uvm_info("SCB_REPORT", $sformatf(
      "APB checked=%0d pass=%0d fail=%0d | PIN checked=%0d pass=%0d fail=%0d",
      apb_checks, apb_pass, apb_fail, pin_checks, pin_pass, pin_fail), UVM_LOW)

    if ((apb_checks == 0) && (pin_checks == 0))
      `uvm_error("SCB_NO_ACTIVITY",
                 "scoreboard checked ZERO transactions (no-activity guard)")
    if ((apb_fail != 0) || (pin_fail != 0))
      `uvm_error("SCB_FAIL", $sformatf("scoreboard mismatches: APB=%0d PIN=%0d",
                 apb_fail, pin_fail))
  endfunction

endclass

`endif // APB_GPIO_SCOREBOARD_SVH
