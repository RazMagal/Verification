// -----------------------------------------------------------------------------
// apb_subsystem_vseq_lib.svh : virtual-sequence library for apb_subsystem.
//
//   Every vseq extends apb_subsystem_base_vseq, runs on the subsystem virtual
//   sequencer, and drives ALL traffic through the ONE upstream active agent:
//     * register + memory access via the hierarchical RAL (root map -> top seqr)
//     * raw APB stimulus (illegal pages, RO writes) via the reused VIP seqlib
//       (apb_read_seq / apb_write_seq) started on p_sequencer.top_seqr.
//
//   vseqs:
//     apb_subsystem_base_vseq        - handles + RAL/raw/wait helpers
//     apb_subsystem_smoke_vseq       - reset-value + RW readback of BOTH timers
//                                      and a memory word (reuse sanity)
//     apb_subsystem_concurrent_timers_vseq (FLAGSHIP) - both timers programmed
//                                      DIFFERENTLY, enabled together, both IRQs
//                                      verified independent + correct (by the two
//                                      nested per-timer ref-model scoreboards)
//     apb_subsystem_mem_vseq         - memory write/readback walk
//     apb_subsystem_decode_error_vseq- unmapped pages + bad timer offsets pslverr
//     apb_subsystem_rand_vseq        - randomized mixed page traffic
//
//   Every vseq touches BOTH timers at least once (touch_timers) so the per-timer
//   sub-scoreboards clear their no-activity guard even in memory/decode tests.
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_VSEQ_LIB_SVH
`define APB_SUBSYSTEM_VSEQ_LIB_SVH

// ---------------------------------------------------------------------------
class apb_subsystem_base_vseq extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(apb_subsystem_base_vseq)
  `uvm_declare_p_sequencer(apb_subsystem_virtual_sequencer)

  apb_subsystem_reg_block regmodel;   // set by the test
  virtual apb_if          vif;        // top u_apb_if (for cycle waits), set by test

  function new(string name = "apb_subsystem_base_vseq");
    super.new(name);
  endfunction

  // Wait n upstream clocks with the bus idle (lets the timers count / time out).
  task wait_cycles(int unsigned n);
    if (vif == null) return;
    repeat (n) @(posedge vif.clk);
  endtask

  // ---- RAL front-door helpers (route to the root map's top sequencer) ----
  task write_reg(uvm_reg r, uvm_reg_data_t data);
    uvm_status_e st;
    r.write(st, data, .parent(this));
    if (st != UVM_IS_OK)
      `uvm_error("VSEQ_WR", $sformatf("write of %s not OK", r.get_full_name()))
  endtask

  task read_reg(uvm_reg r, output uvm_reg_data_t data);
    uvm_status_e st;
    r.read(st, data, .parent(this));
    if (st != UVM_IS_OK)
      `uvm_error("VSEQ_RD", $sformatf("read of %s not OK", r.get_full_name()))
  endtask

  task check_reg(uvm_reg r, uvm_reg_data_t exp,
                 uvm_reg_data_t mask = 32'hFFFF_FFFF);
    uvm_reg_data_t got;
    read_reg(r, got);
    if ((got & mask) !== (exp & mask))
      `uvm_error("VSEQ_CHK", $sformatf("%s read=0x%08h exp=0x%08h (mask=0x%08h)",
                 r.get_full_name(), got, exp, mask))
    else
      `uvm_info("VSEQ_CHK", $sformatf("%s == 0x%08h OK", r.get_full_name(),
                exp & mask), UVM_MEDIUM)
  endtask

  // ---- memory helpers via the RAL uvm_mem (word offset) ----
  task mem_write(int unsigned word, bit [31:0] data);
    uvm_status_e st;
    regmodel.mem.write(st, word, data, .parent(this));
    if (st != UVM_IS_OK)
      `uvm_error("VSEQ_MEMWR", $sformatf("mem[%0d] write not OK", word))
  endtask

  task mem_read(int unsigned word, output bit [31:0] data);
    uvm_status_e   st;
    uvm_reg_data_t d;
    regmodel.mem.read(st, word, d, .parent(this));
    data = d[31:0];
    if (st != UVM_IS_OK)
      `uvm_error("VSEQ_MEMRD", $sformatf("mem[%0d] read not OK", word))
  endtask

  // ---- raw upstream APB access (reuses the VIP seqlib on the top sequencer) ----
  task raw_read(bit [11:0] addr, output apb_seq_item done);
    apb_read_seq rd = apb_read_seq::type_id::create("rd");
    rd.addr = addr;
    rd.start(p_sequencer.top_seqr, this);
    done = rd.item;
  endtask

  task raw_write(bit [11:0] addr, bit [31:0] data, output apb_seq_item done);
    apb_write_seq wr = apb_write_seq::type_id::create("wr");
    wr.addr  = addr;
    wr.wdata = data;
    wr.start(p_sequencer.top_seqr, this);
    done = wr.item;
  endtask

  // Poke both timers once so each nested sub-scoreboard clears its activity guard.
  task touch_timers();
    uvm_reg_data_t d;
    read_reg(regmodel.timer0.CTRL, d);
    read_reg(regmodel.timer1.CTRL, d);
  endtask
endclass

// ---------------------------------------------------------------------------
// Smoke : reset-value + RW readback across BOTH reused timer blocks + a mem word.
class apb_subsystem_smoke_vseq extends apb_subsystem_base_vseq;
  `uvm_object_utils(apb_subsystem_smoke_vseq)
  function new(string name = "apb_subsystem_smoke_vseq"); super.new(name); endfunction

  task body();
    bit [31:0] rd;
    regmodel.reset();

    // reset values (hierarchical RAL mirror check across both timer instances)
    check_reg(regmodel.timer0.CTRL,   32'h0);
    check_reg(regmodel.timer0.STATUS, 32'h0);
    check_reg(regmodel.timer1.CTRL,   32'h0);
    check_reg(regmodel.timer1.STATUS, 32'h0);

    // RW readback per timer, at DIFFERENT pages (proves decode + reuse)
    write_reg(regmodel.timer0.LOAD,     32'h1111_2222);
    check_reg(regmodel.timer0.LOAD,     32'h1111_2222);
    write_reg(regmodel.timer0.PRESCALE, 32'h0000_00AB);
    check_reg(regmodel.timer0.PRESCALE, 32'h0000_00AB);   // [31:8] reserved read 0
    write_reg(regmodel.timer1.LOAD,     32'h3333_4444);
    check_reg(regmodel.timer1.LOAD,     32'h3333_4444);
    write_reg(regmodel.timer1.CTRL,     32'h0000_0006);   // MODE|IRQ_EN, EN=0
    check_reg(regmodel.timer1.CTRL,     32'h0000_0006);

    // one memory word round-trip
    mem_write(0, 32'hCAFE_F00D);
    mem_read (0, rd);
    if (rd !== 32'hCAFE_F00D)
      `uvm_error("SMOKE_MEM", $sformatf("mem[0] readback 0x%08h", rd))
  endtask
endclass

// ---------------------------------------------------------------------------
// FLAGSHIP : both timers programmed differently, enabled together, both IRQs
// verified independent + correct (exact checking by the two nested per-timer
// ref-model scoreboards on t0_if/irq0 and t1_if/irq1).
class apb_subsystem_concurrent_timers_vseq extends apb_subsystem_base_vseq;
  `uvm_object_utils(apb_subsystem_concurrent_timers_vseq)
  function new(string name = "apb_subsystem_concurrent_timers_vseq");
    super.new(name);
  endfunction

  task body();
    regmodel.reset();

    // timer0 : PERIODIC, IRQ_EN, fast  (load=4, prescale=0 -> fires every 4 cyc)
    write_reg(regmodel.timer0.PRESCALE, 32'h0000_0000);
    write_reg(regmodel.timer0.LOAD,     32'h0000_0004);
    // timer1 : ONE-SHOT, IRQ_EN, slower (load=6, prescale=1 -> fires ~12 cyc)
    write_reg(regmodel.timer1.PRESCALE, 32'h0000_0001);
    write_reg(regmodel.timer1.LOAD,     32'h0000_0006);

    // enable BOTH back-to-back so they count concurrently
    write_reg(regmodel.timer0.CTRL, 32'h0000_0007);   // EN | MODE(periodic) | IRQ_EN
    write_reg(regmodel.timer1.CTRL, 32'h0000_0005);   // EN | IRQ_EN, one-shot

    // let them run overlapping
    wait_cycles(40);

    // timer1 (one-shot) fired once: STATUS.IRQ set, EN auto-cleared, IRQ_EN kept
    check_reg(regmodel.timer1.STATUS, 32'h1, 32'h1);
    check_reg(regmodel.timer1.CTRL,   32'h0000_0004, 32'h0000_0007);
    // clear timer1 while IRQ_EN still set so irq1 actually falls (edge balance)
    write_reg(regmodel.timer1.STATUS, 32'h1);
    check_reg(regmodel.timer1.STATUS, 32'h0, 32'h1);

    // timer0 (periodic) still enabled and has fired (independent of timer1)
    check_reg(regmodel.timer0.STATUS, 32'h1, 32'h1);
    check_reg(regmodel.timer0.CTRL,   32'h0000_0007, 32'h0000_0007);

    // stop + clear timer0 (CTRL=0 clears IRQ_EN -> irq0 falls)
    write_reg(regmodel.timer0.CTRL,   32'h0000_0000);
    write_reg(regmodel.timer0.STATUS, 32'h1);
    wait_cycles(8);
    check_reg(regmodel.timer0.STATUS, 32'h0, 32'h1);
  endtask
endclass

// ---------------------------------------------------------------------------
// Memory : write/readback walk across the 64-word region (shadow-checked too).
class apb_subsystem_mem_vseq extends apb_subsystem_base_vseq;
  `uvm_object_utils(apb_subsystem_mem_vseq)
  function new(string name = "apb_subsystem_mem_vseq"); super.new(name); endfunction

  task body();
    bit [31:0] wdata, rd;
    regmodel.reset();
    touch_timers();

    // sequential words
    for (int unsigned i = 0; i < 16; i++) begin
      wdata = 32'hA5A5_0000 + i;
      mem_write(i, wdata);
      mem_read (i, rd);
      if (rd !== wdata)
        `uvm_error("MEM_VSEQ", $sformatf("mem[%0d] wrote 0x%08h read 0x%08h",
                   i, wdata, rd))
    end

    // boundary words
    mem_write(63, 32'hDEAD_BEEF);
    mem_read (63, rd);
    if (rd !== 32'hDEAD_BEEF)
      `uvm_error("MEM_VSEQ", $sformatf("mem[63] read 0x%08h", rd))

    // overwrite + re-read (proves last-write-wins)
    mem_write(0, 32'h1234_5678);
    mem_read (0, rd);
    if (rd !== 32'h1234_5678)
      `uvm_error("MEM_VSEQ", $sformatf("mem[0] overwrite read 0x%08h", rd))
  endtask
endclass

// ---------------------------------------------------------------------------
// Decode error : unmapped pages + illegal timer offsets must pslverr; legal must not.
class apb_subsystem_decode_error_vseq extends apb_subsystem_base_vseq;
  `uvm_object_utils(apb_subsystem_decode_error_vseq)
  function new(string name = "apb_subsystem_decode_error_vseq");
    super.new(name);
  endfunction

  task body();
    apb_seq_item it;
    bit [11:0]   bad_pages[$] = '{12'h300, 12'h400, 12'h700, 12'hF00, 12'h3FC};
    regmodel.reset();
    touch_timers();

    // unmapped pages -> fabric pslverr, rdata 0 (both directions)
    foreach (bad_pages[i]) begin
      raw_read(bad_pages[i], it);
      if (!it.slverr || (it.rdata !== 32'h0))
        `uvm_error("DEC_VSEQ", $sformatf(
                   "unmapped read @0x%03h slverr=%0b rdata=0x%08h",
                   bad_pages[i], it.slverr, it.rdata))
      raw_write(bad_pages[i], 32'hDEAD_BEEF, it);
      if (!it.slverr)
        `uvm_error("DEC_VSEQ", $sformatf("unmapped write @0x%03h no pslverr",
                   bad_pages[i]))
    end

    // mapped timer page, ILLEGAL register offset -> timer pslverr, rdata 0
    raw_read(12'h014, it);        // timer0 page, offset 0x14 (unmapped)
    if (!it.slverr || (it.rdata !== 32'h0))
      `uvm_error("DEC_VSEQ", $sformatf("timer0 bad-offset read slverr=%0b rdata=0x%08h",
                 it.slverr, it.rdata))
    raw_read(12'h103, it);        // timer1 page, unaligned offset 0x03
    if (!it.slverr)
      `uvm_error("DEC_VSEQ", "timer1 unaligned read did not pslverr")

    // mapped LEGAL accesses must NOT error
    raw_read(12'h000, it);        // timer0 CTRL
    if (it.slverr) `uvm_error("DEC_VSEQ", "timer0 CTRL read spuriously errored")
    raw_read(12'h108, it);        // timer1 VALUE (RO, legal)
    if (it.slverr) `uvm_error("DEC_VSEQ", "timer1 VALUE read spuriously errored")
    raw_write(12'h108, 32'hFFFF_FFFF, it);   // RO write : legal, no error, no effect
    if (it.slverr) `uvm_error("DEC_VSEQ", "timer1 VALUE RO write raised pslverr")
    raw_read(12'h2A4, it);        // mem word (page 2) : legal, never errors
    if (it.slverr) `uvm_error("DEC_VSEQ", "mem read spuriously errored")
  endtask
endclass

// ---------------------------------------------------------------------------
// Random : mixed page traffic (timers, mem, decode errors, short timeouts).
class apb_subsystem_rand_vseq extends apb_subsystem_base_vseq;
  `uvm_object_utils(apb_subsystem_rand_vseq)

  rand int unsigned n_ops;
  constraint c_n { n_ops inside {[16:32]}; }

  function new(string name = "apb_subsystem_rand_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    apb_seq_item   it;
    bit [31:0]     rd;
    regmodel.reset();
    touch_timers();

    repeat (n_ops) begin
      int unsigned sel = $urandom_range(0, 6);
      case (sel)
        0: write_reg(regmodel.timer0.LOAD,     $urandom_range(0, 12));
        1: write_reg(regmodel.timer1.PRESCALE, $urandom_range(0, 5));
        2: begin
             int unsigned w = $urandom_range(0, 63);
             mem_write(w, $urandom);
             mem_read (w, rd);
           end
        3: begin
             bit [3:0] pg = $urandom_range(3, 15);   // unmapped page
             raw_read({pg, 8'h00}, it);
           end
        4: begin
             // short one-shot on a random timer, then clear
             int unsigned t = $urandom_range(0, 1);
             uvm_reg pre = (t == 0) ? regmodel.timer0.PRESCALE
                                    : regmodel.timer1.PRESCALE;
             uvm_reg ld  = (t == 0) ? regmodel.timer0.LOAD  : regmodel.timer1.LOAD;
             uvm_reg ct  = (t == 0) ? regmodel.timer0.CTRL  : regmodel.timer1.CTRL;
             uvm_reg stt = (t == 0) ? regmodel.timer0.STATUS: regmodel.timer1.STATUS;
             write_reg(pre, $urandom_range(0, 2));
             write_reg(ld,  $urandom_range(1, 5));
             write_reg(ct,  32'h0000_0005);        // EN, one-shot, IRQ_EN
             wait_cycles($urandom_range(8, 24));
             write_reg(stt, 32'h1);                // clear
           end
        5: read_reg(regmodel.timer0.VALUE, d);
        6: read_reg(regmodel.timer1.STATUS, d);
        default: ;
      endcase
    end

    // quiesce : stop + clear both timers (irq lines return low, edges balance)
    write_reg(regmodel.timer0.CTRL,   32'h0);
    write_reg(regmodel.timer1.CTRL,   32'h0);
    write_reg(regmodel.timer0.STATUS, 32'h1);
    write_reg(regmodel.timer1.STATUS, 32'h1);
    wait_cycles(8);
  endtask
endclass

`endif // APB_SUBSYSTEM_VSEQ_LIB_SVH
