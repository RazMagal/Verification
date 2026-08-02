// -----------------------------------------------------------------------------
// apb_timer_scoreboard.svh : reference-model scoreboard for apb_timer.
//
//   Two paired streams, each via its own uvm_tlm_analysis_fifo so the single
//   write() collision is avoided and pairing is strictly in-order:
//     APB : expected (from apb_timer_ref_model) vs actual (from apb_monitor)
//     IRQ : expected (from apb_timer_ref_model) vs actual (from irq monitor)
//
//   Checks (exact unless noted):
//     * APB READ  : dir/addr/slverr exact; rdata exact for CTRL/LOAD/STATUS/
//                   PRESCALE/reserved and for unmapped (rdata==0, slverr==1).
//                   VALUE (live counter) rdata exact-preferred with a documented
//                   +/-1 tolerance for sampling skew.
//     * APB WRITE : dir/addr/slverr exact (unmapped -> slverr; legal incl. RO
//                   VALUE -> no slverr).
//     * IRQ       : edge polarity (rose/fell) EXACT and in-order; cycle stamp
//                   within +/-1 (sampling skew). One-shot EN auto-clear /
//                   periodic re-assert / W1C are nailed EXACTLY by the STATUS
//                   and CTRL read checks above.
//
//   check_phase: reports pass/fail counts, drains any UNMATCHED items (a leftover
//   in either fifo is an error), and FAILS if nothing was checked (activity guard).
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_SCOREBOARD_SVH
`define APB_TIMER_SCOREBOARD_SVH

class apb_timer_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(apb_timer_scoreboard)

  // APB streams.
  uvm_tlm_analysis_fifo #(apb_seq_item)   apb_exp_fifo;
  uvm_tlm_analysis_fifo #(apb_seq_item)   apb_act_fifo;
  // IRQ streams.
  uvm_tlm_analysis_fifo #(timer_irq_item) irq_exp_fifo;
  uvm_tlm_analysis_fifo #(timer_irq_item) irq_act_fifo;

  int unsigned apb_checks, apb_pass, apb_fail;
  int unsigned irq_checks, irq_pass, irq_fail;

  localparam bit [APB_TIMER_ADDR_WIDTH-1:0] VALUE_OFF = 'h08;

  function new(string name = "apb_timer_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    apb_exp_fifo = new("apb_exp_fifo", this);
    apb_act_fifo = new("apb_act_fifo", this);
    irq_exp_fifo = new("irq_exp_fifo", this);
    irq_act_fifo = new("irq_act_fifo", this);
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    fork
      check_apb();
      check_irq();
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
      // The reference model is cycle-exact (its shadow at posedge k equals the
      // registers the monitor samples during cycle k), so EVERY read -- VALUE
      // included -- must match exactly. A tolerance here would only ever mask a
      // genuine off-by-one counter bug, which is precisely what this env exists
      // to catch.
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

  // ---- IRQ expected vs actual (in-order) ----
  task check_irq();
    timer_irq_item exp, act;
    forever begin
      irq_exp_fifo.get(exp);
      irq_act_fifo.get(act);
      irq_checks++;
      compare_irq(exp, act);
    end
  endtask

  function void compare_irq(timer_irq_item exp, timer_irq_item act);
    bit err = 1'b0;
    int unsigned dcyc;
    if ((exp.rose !== act.rose) || (exp.fell !== act.fell) ||
        (exp.irq !== act.irq)) begin
      err = 1'b1;
      `uvm_error("SCB_IRQ_EDGE", $sformatf(
                 "irq edge mismatch exp{%s} act{%s}",
                 exp.convert2string(), act.convert2string()))
    end
    else begin
      dcyc = (exp.cyc > act.cyc) ? (exp.cyc - act.cyc) : (act.cyc - exp.cyc);
      // Edges are cycle-aligned in the exact model (dcyc==0 on good hardware),
      // so require an exact cycle match -- a 1-cycle-late/early irq is a bug.
      if (dcyc > 0) begin
        err = 1'b1;
        `uvm_error("SCB_IRQ_TIME", $sformatf(
                   "irq edge cycle off by %0d (exp cyc=%0d act cyc=%0d)",
                   dcyc, exp.cyc, act.cyc))
      end
      else begin
        `uvm_info("SCB_IRQ_OK", $sformatf("IRQ MATCH %s (dcyc=%0d)",
                  act.convert2string(), dcyc), UVM_MEDIUM)
      end
    end
    if (err) irq_fail++;
    else     irq_pass++;
  endfunction

  // ---- drain leftovers + report ----
  function void check_phase(uvm_phase phase);
    apb_seq_item   a;
    timer_irq_item i;
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
    while (irq_exp_fifo.try_get(i)) begin
      irq_fail++;
      `uvm_error("SCB_IRQ_UNMATCHED_EXP",
                 $sformatf("expected IRQ with no actual: %s", i.convert2string()))
    end
    while (irq_act_fifo.try_get(i)) begin
      irq_fail++;
      `uvm_error("SCB_IRQ_UNMATCHED_ACT",
                 $sformatf("actual IRQ with no expected: %s", i.convert2string()))
    end

    `uvm_info("SCB_REPORT", $sformatf(
      "APB checked=%0d pass=%0d fail=%0d | IRQ checked=%0d pass=%0d fail=%0d",
      apb_checks, apb_pass, apb_fail, irq_checks, irq_pass, irq_fail), UVM_LOW)

    if ((apb_checks == 0) && (irq_checks == 0))
      `uvm_error("SCB_NO_ACTIVITY",
                 "scoreboard checked ZERO transactions (no-activity guard)")
    if ((apb_fail != 0) || (irq_fail != 0))
      `uvm_error("SCB_FAIL", $sformatf("scoreboard mismatches: APB=%0d IRQ=%0d",
                 apb_fail, irq_fail))
  endfunction

endclass

`endif // APB_TIMER_SCOREBOARD_SVH
