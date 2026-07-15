// -----------------------------------------------------------------------------
// apb_gpio_vseq_lib.svh : virtual-sequence library layered over the RAL, the APB
//   sequencer and the pin sequencer. Every vseq extends apb_gpio_base_vseq which
//   carries the RAL block handle, a virtual apb_if (for cycle waits), a handle to
//   the pin sequencer (for driving gpio_in) and helper tasks.
//
//   vseqs:
//     apb_gpio_base_vseq          - handles + helpers (reg + pin drive + waits)
//     apb_gpio_smoke_vseq         - reset check + RW/RO/W1C readback
//     apb_gpio_output_drive_vseq  - DATA_OUT->gpio_out, DIR->gpio_oe
//     apb_gpio_input_capture_vseq - drive gpio_in, read DATA_IN through the sync
//     apb_gpio_interrupt_vseq     - edge sets INT_STATUS, irq gated by INT_EN,
//                                   with mask/unmask of a pending flag
//     apb_gpio_w1c_vseq           - W1C + HW-set-wins race (toggle input vs W1C)
//     apb_gpio_error_vseq         - unmapped/unaligned -> pslverr; RO DATA_IN
//                                   write -> no pslverr, no effect
//     apb_gpio_reg_vseq           - uvm_reg_hw_reset_seq + uvm_reg_bit_bash_seq
//     apb_gpio_rand_vseq          - randomized mixed register + pin traffic
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_VSEQ_LIB_SVH
`define APB_GPIO_VSEQ_LIB_SVH

// ---------------------------------------------------------------------------
class apb_gpio_base_vseq extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(apb_gpio_base_vseq)

  apb_gpio_reg_block         regmodel;   // set by the test
  virtual apb_if             vif;        // set by the test (for wait_cycles)
  uvm_sequencer #(gpio_item) pin_seqr;   // set by the test (pin driver)

  function new(string name = "apb_gpio_base_vseq");
    super.new(name);
  endfunction

  // Wait n APB clocks with the bus idle (lets the synchronizer/edges settle).
  task wait_cycles(int unsigned n);
    if (vif == null) return;
    repeat (n) @(posedge vif.clk);
  endtask

  // ---- RAL front-door helpers ----
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

  // Raw APB access (bypasses RAL; used for illegal/RO stimulus).
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

  // ---- pin-drive helpers (issued on the pin sequencer) ----
  task pin_op(gpio_op_e op, bit [31:0] mask, bit [31:0] value = 32'h0,
              int unsigned hold = 1);
    gpio_item it;
    if (pin_seqr == null) return;
    it = gpio_item::type_id::create("pin");
    start_item(it, -1, pin_seqr);
    it.op    = op;
    it.mask  = mask;
    it.value = value;
    it.hold  = hold;
    finish_item(it);
  endtask

  task drive_pins(bit [31:0] value, bit [31:0] mask = 32'hFFFF_FFFF,
                  int unsigned hold = 1);
    pin_op(GPIO_DRIVE, mask, value, hold);
  endtask
  task set_pins   (bit [31:0] mask, int unsigned hold = 1); pin_op(GPIO_SET,    mask, 32'h0, hold); endtask
  task clear_pins (bit [31:0] mask, int unsigned hold = 1); pin_op(GPIO_CLEAR,  mask, 32'h0, hold); endtask
  task toggle_pins(bit [31:0] mask, int unsigned hold = 1); pin_op(GPIO_TOGGLE, mask, 32'h0, hold); endtask
endclass

// ---------------------------------------------------------------------------
// Smoke : RAL reset mirror check + basic RW / RO / W1C readback (no edges).
class apb_gpio_smoke_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_smoke_vseq)
  function new(string name = "apb_gpio_smoke_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();                       // mirror -> reset (all 0)
    // reset-value read check
    check_reg(regmodel.DATA_OUT,   32'h0);
    check_reg(regmodel.DATA_IN,    32'h0);
    check_reg(regmodel.DIR,        32'h0);
    check_reg(regmodel.INT_STATUS, 32'h0);
    check_reg(regmodel.INT_EN,     32'h0);
    // RW readback of DATA_OUT / DIR / INT_EN.
    write_reg(regmodel.DATA_OUT, 32'hA5A5_5A5A);
    check_reg(regmodel.DATA_OUT, 32'hA5A5_5A5A);
    write_reg(regmodel.DIR,      32'h0F0F_F0F0);
    check_reg(regmodel.DIR,      32'h0F0F_F0F0);
    write_reg(regmodel.INT_EN,   32'hFFFF_0000);
    check_reg(regmodel.INT_EN,   32'hFFFF_0000);
    // RO DATA_IN : writing it is silently dropped, stays 0 (no pins driven).
    write_reg(regmodel.DATA_IN,  32'hDEAD_BEEF);
    check_reg(regmodel.DATA_IN,  32'h0);
    // W1C INT_STATUS : nothing set, writing 1s leaves it 0.
    write_reg(regmodel.INT_STATUS, 32'hFFFF_FFFF);
    check_reg(regmodel.INT_STATUS, 32'h0);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Output drive : DATA_OUT -> gpio_out, DIR -> gpio_oe (checked by scb + SVA).
class apb_gpio_output_drive_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_output_drive_vseq)
  function new(string name = "apb_gpio_output_drive_vseq"); super.new(name); endfunction

  task body();
    bit [31:0] pats [4] = '{32'h0000_0000, 32'hFFFF_FFFF,
                            32'hA5A5_A5A5, 32'h0000_00FF};
    regmodel.reset();
    foreach (pats[i]) begin
      write_reg(regmodel.DIR,      pats[i]);        // -> gpio_oe
      write_reg(regmodel.DATA_OUT, ~pats[i]);       // -> gpio_out
      wait_cycles(3);                               // let outputs settle + score
      check_reg(regmodel.DIR,      pats[i]);
      check_reg(regmodel.DATA_OUT, ~pats[i]);
    end
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Input capture : drive gpio_in, read DATA_IN back through the 2-FF sync.
class apb_gpio_input_capture_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_input_capture_vseq)

  rand bit [31:0] pat0;
  rand bit [31:0] pat1;
  constraint c_pats { pat0 != pat1; }

  function new(string name = "apb_gpio_input_capture_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();
    // drive a pattern, wait for it to propagate through both sync flops, read.
    drive_pins(pat0);
    wait_cycles(5);                       // 2-FF sync latency + margin
    check_reg(regmodel.DATA_IN, pat0);
    // change it, confirm DATA_IN tracks the synchronized pins.
    drive_pins(pat1);
    wait_cycles(5);
    check_reg(regmodel.DATA_IN, pat1);
    // per-pin set/clear.
    clear_pins(32'hFFFF_FFFF);
    wait_cycles(5);
    check_reg(regmodel.DATA_IN, 32'h0);
    set_pins(32'h0000_00FF);
    wait_cycles(5);
    check_reg(regmodel.DATA_IN, 32'h0000_00FF);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Interrupt : a rising edge sets INT_STATUS; irq = |(INT_STATUS & INT_EN).
//   Includes mask/unmask of a PENDING flag (like the timer irq_mask vseq): raise
//   the flag while MASKED (INT_EN=0 -> irq low), UNMASK (irq rises with no new
//   edge), RE-MASK (irq drops, flag stays), then W1C-clear. Every edge is checked
//   continuously by the bound SVA and the reference-model scoreboard.
class apb_gpio_interrupt_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_interrupt_vseq)
  function new(string name = "apb_gpio_interrupt_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();
    // start with all inputs low so the first rising edge is unambiguous.
    clear_pins(32'hFFFF_FFFF);
    wait_cycles(4);

    // 1) Arm the flag while MASKED : INT_EN=0, then create a rising edge on pin0.
    write_reg(regmodel.INT_EN, 32'h0);
    set_pins(32'h0000_0001);               // 0 -> 1 rising edge on pin 0
    wait_cycles(5);                         // edge propagates + sets INT_STATUS
    check_reg(regmodel.INT_STATUS, 32'h1, 32'h1);   // pending
    // masked -> irq must be low (proven by the bound p_irq_level SVA).

    // 2) UNMASK the pending flag : irq rises with NO new edge.
    write_reg(regmodel.INT_EN, 32'h0000_0001);
    wait_cycles(4);
    check_reg(regmodel.INT_STATUS, 32'h1, 32'h1);   // still pending

    // 3) RE-MASK without clearing : irq drops, flag stays set (sticky).
    write_reg(regmodel.INT_EN, 32'h0);
    wait_cycles(4);
    check_reg(regmodel.INT_STATUS, 32'h1, 32'h1);

    // 4) Unmask again, then W1C-clear : flag and irq drop together.
    write_reg(regmodel.INT_EN, 32'h0000_0001);
    wait_cycles(2);
    write_reg(regmodel.INT_STATUS, 32'h1);          // W1C bit 0
    check_reg(regmodel.INT_STATUS, 32'h0, 32'h1);   // cleared
    wait_cycles(4);

    // 5) Multi-pin edges with a full enable mask.
    write_reg(regmodel.INT_EN, 32'hFFFF_FFFF);
    set_pins(32'h0000_00F0);                // rising edges on pins [7:4]
    wait_cycles(5);
    check_reg(regmodel.INT_STATUS, 32'h0000_00F0, 32'h0000_00F0);
    write_reg(regmodel.INT_STATUS, 32'h0000_00F0);  // W1C clear
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Pin-toggle sub-sequence : drives repeated 0->1->0 pulses on `mask`, one clock
//   high / one clock low, so a fresh rising edge is generated every ~2 clocks.
//   Run on the pin sequencer (concurrently with W1C traffic) to provoke the
//   HW-set-wins race.
class apb_gpio_pin_toggle_seq extends uvm_sequence #(gpio_item);
  `uvm_object_utils(apb_gpio_pin_toggle_seq)

  bit [31:0]   mask = 32'h0000_0001;
  int unsigned n    = 20;

  function new(string name = "apb_gpio_pin_toggle_seq"); super.new(name); endfunction

  task body();
    repeat (n) begin
      gpio_item it;
      it = gpio_item::type_id::create("tg");
      start_item(it);
      it.op = GPIO_SET; it.mask = mask; it.value = 32'h0; it.hold = 1;
      finish_item(it);
      it = gpio_item::type_id::create("tg");
      start_item(it);
      it.op = GPIO_CLEAR; it.mask = mask; it.value = 32'h0; it.hold = 1;
      finish_item(it);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// W1C : write-1-to-clear semantics + HW-set-wins race.
class apb_gpio_w1c_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_w1c_vseq)
  function new(string name = "apb_gpio_w1c_vseq"); super.new(name); endfunction

  task body();
    apb_gpio_pin_toggle_seq tg;
    regmodel.reset();
    clear_pins(32'hFFFF_FFFF);
    wait_cycles(4);

    // 1) set a flag via a rising edge on pin 0 (INT_EN=0 keeps irq low).
    write_reg(regmodel.INT_EN, 32'h0);
    set_pins(32'h0000_0001);
    wait_cycles(5);
    check_reg(regmodel.INT_STATUS, 32'h1, 32'h1);
    // 2) writing 0 must NOT clear (W1C).
    write_reg(regmodel.INT_STATUS, 32'h0);
    check_reg(regmodel.INT_STATUS, 32'h1, 32'h1);
    // 3) writing 1 clears.
    write_reg(regmodel.INT_STATUS, 32'h1);
    check_reg(regmodel.INT_STATUS, 32'h0, 32'h1);

    // 4) HW-set-wins race : CONCURRENTLY generate fresh rising edges on pin 0
    //    (on the pin sequencer) while hammering W1C (on the APB sequencer). The
    //    2-FF synchronizer jitters the HW set against the W1C ACCESS beats, so
    //    some sets land on the same clock as a W1C to bit 0; the flag then stays
    //    set (HW wins). Checked exactly by the bound SVA / ref model and covered
    //    by cg_evt.w1c_race. Independent sequencers => no arbitration conflict.
    tg = apb_gpio_pin_toggle_seq::type_id::create("tg");
    tg.mask = 32'h0000_0001;
    tg.n    = 24;
    fork
      tg.start(pin_seqr);
      begin
        repeat (40) write_reg(regmodel.INT_STATUS, 32'h1);
      end
    join

    // stop generating edges (drive low) and do a final clean clear.
    clear_pins(32'hFFFF_FFFF);
    wait_cycles(6);
    write_reg(regmodel.INT_STATUS, 32'hFFFF_FFFF);
    wait_cycles(4);
    check_reg(regmodel.INT_STATUS, 32'h0, 32'h1);
  endtask
endclass

// ---------------------------------------------------------------------------
// Error : unmapped / unaligned accesses raise pslverr; RO DATA_IN write must not.
class apb_gpio_error_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_error_vseq)
  function new(string name = "apb_gpio_error_vseq"); super.new(name); endfunction

  task body();
    apb_seq_item it;
    regmodel.reset();
    // unmapped read (0x14 is just past INT_EN).
    raw_access(APB_READ, 8'h14, 32'h0, it);
    if (!it.slverr || (it.rdata !== 32'h0))
      `uvm_error("ERR_VSEQ", $sformatf("unmapped read: slverr=%0b rdata=0x%08h",
                 it.slverr, it.rdata))
    // unaligned read (0x02).
    raw_access(APB_READ, 8'h02, 32'h0, it);
    if (!it.slverr)
      `uvm_error("ERR_VSEQ", "unaligned read did not raise pslverr")
    // unmapped write.
    raw_access(APB_WRITE, 8'h80, 32'hDEAD_BEEF, it);
    if (!it.slverr)
      `uvm_error("ERR_VSEQ", "unmapped write did not raise pslverr")
    // legal write to RO DATA_IN : NO pslverr, no effect.
    raw_access(APB_WRITE, 8'h04, 32'h1234_5678, it);
    if (it.slverr)
      `uvm_error("ERR_VSEQ", "RO DATA_IN write raised pslverr (should not)")
    // DATA_IN still 0 (no pins driven).
    raw_access(APB_READ, 8'h04, 32'h0, it);
    if (it.rdata !== 32'h0)
      `uvm_error("ERR_VSEQ", $sformatf("RO DATA_IN changed: 0x%08h", it.rdata))
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// RAL showcase : run the built-in hw-reset and bit-bash register sequences.
//   DATA_IN (RO/volatile) and INT_STATUS (W1C/HW-set) are excluded from bit-bash
//   at the reg_block; gpio_in is held at 0 by the pin driver so no edge sets
//   INT_STATUS during the walk.
class apb_gpio_reg_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_reg_vseq)
  function new(string name = "apb_gpio_reg_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_hw_reset_seq hw;
    uvm_reg_bit_bash_seq bb;

    regmodel.reset();
    clear_pins(32'hFFFF_FFFF);       // keep inputs quiet during the register walk
    wait_cycles(5);

    hw = uvm_reg_hw_reset_seq::type_id::create("hw");
    hw.model = regmodel;
    hw.start(null);

    bb = uvm_reg_bit_bash_seq::type_id::create("bb");
    bb.model = regmodel;
    bb.start(null);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Random : randomized mixed register + pin traffic.
class apb_gpio_rand_vseq extends apb_gpio_base_vseq;
  `uvm_object_utils(apb_gpio_rand_vseq)

  rand int unsigned n_ops;
  constraint c_n { n_ops inside {[12:24]}; }

  function new(string name = "apb_gpio_rand_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    regmodel.reset();
    repeat (n_ops) begin
      int unsigned sel = $urandom_range(0, 8);
      case (sel)
        0: write_reg(regmodel.DATA_OUT, $urandom);
        1: write_reg(regmodel.DIR,      $urandom);
        2: write_reg(regmodel.INT_EN,   $urandom);
        3: write_reg(regmodel.INT_STATUS, $urandom);       // random W1C
        4: read_reg (regmodel.DATA_IN,  d);
        5: read_reg (regmodel.INT_STATUS, d);
        6: drive_pins($urandom, $urandom, $urandom_range(1, 3));
        7: begin
             set_pins($urandom, $urandom_range(1, 2));
             wait_cycles($urandom_range(2, 5));
           end
        8: begin
             toggle_pins($urandom, 1);
             wait_cycles($urandom_range(1, 4));
           end
        default: ;
      endcase
    end
    // settle : drive inputs low and clear any pending flags.
    clear_pins(32'hFFFF_FFFF);
    wait_cycles(6);
    write_reg(regmodel.INT_STATUS, 32'hFFFF_FFFF);
    wait_cycles(4);
  endtask
endclass

`endif // APB_GPIO_VSEQ_LIB_SVH
