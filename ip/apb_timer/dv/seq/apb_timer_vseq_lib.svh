// -----------------------------------------------------------------------------
// apb_timer_vseq_lib.svh : virtual-sequence library layered over the RAL and
//   the APB sequencer. Every vseq extends apb_timer_base_vseq which carries the
//   RAL block handle + a virtual apb_if (for cycle waits) and helper tasks.
//
//   vseqs:
//     apb_timer_base_vseq       - handles + helpers (write_reg/read_reg/wait)
//     apb_timer_smoke_vseq      - RAL reset check + CTRL/LOAD/PRESCALE readback
//     apb_timer_oneshot_vseq    - one-shot timeout, IRQ+STATUS+EN auto-clear, W1C
//     apb_timer_periodic_vseq   - periodic N timeouts, each STATUS clear
//     apb_timer_prescale_vseq   - PRESCALE>0 timeout latency
//     apb_timer_w1c_vseq        - STATUS write-1-to-clear + HW-set-wins race
//     apb_timer_error_vseq      - unmapped/unaligned accesses -> pslverr
//     apb_timer_reg_hw_reset_vseq - built-in uvm_reg_hw_reset + bit_bash seqs
//     apb_timer_rand_vseq       - randomized legal register + enable traffic
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_VSEQ_LIB_SVH
`define APB_TIMER_VSEQ_LIB_SVH

// ---------------------------------------------------------------------------
class apb_timer_base_vseq extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(apb_timer_base_vseq)

  apb_timer_reg_block regmodel;   // set by the test
  virtual apb_if      vif;        // set by the test (for wait_cycles)

  function new(string name = "apb_timer_base_vseq");
    super.new(name);
  endfunction

  // Wait n APB clocks with the bus idle (lets the timer count / time out).
  task wait_cycles(int unsigned n);
    if (vif == null) return;
    repeat (n) @(posedge vif.clk);
  endtask

  // RAL front-door helpers.
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
endclass

// ---------------------------------------------------------------------------
// Smoke : RAL reset mirror check + basic RW readback (no counting).
class apb_timer_smoke_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_smoke_vseq)
  function new(string name = "apb_timer_smoke_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();                       // mirror -> reset (all 0)
    // reset-value read check
    check_reg(regmodel.CTRL,     32'h0);
    check_reg(regmodel.LOAD,     32'h0);
    check_reg(regmodel.VALUE,    32'h0);
    check_reg(regmodel.STATUS,   32'h0);
    check_reg(regmodel.PRESCALE, 32'h0);
    // RW readback (MODE|IRQ_EN, EN kept 0 so nothing counts). Full-width checks
    // also prove the reserved bits read back 0 (written value has them 0).
    write_reg(regmodel.CTRL,     32'h0000_0006);
    check_reg(regmodel.CTRL,     32'h0000_0006);   // [31:3] reserved read 0
    write_reg(regmodel.LOAD,     32'h1234_5678);
    check_reg(regmodel.LOAD,     32'h1234_5678);
    write_reg(regmodel.PRESCALE, 32'h0000_00AB);
    check_reg(regmodel.PRESCALE, 32'h0000_00AB);   // [31:8] reserved read 0
  endtask
endclass

// ---------------------------------------------------------------------------
// One-shot timeout : IRQ asserts, STATUS.IRQ set, EN auto-clears, then W1C.
class apb_timer_oneshot_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_oneshot_vseq)

  rand bit [31:0] load_val;
  rand bit [7:0]  presc_val;
  constraint c_bounded { load_val inside {[1:8]}; presc_val inside {[0:3]}; }

  function new(string name = "apb_timer_oneshot_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();
    write_reg(regmodel.PRESCALE, presc_val);
    write_reg(regmodel.LOAD,     load_val);
    // EN=1, MODE=0 (one-shot), IRQ_EN=1  -> 0b101
    write_reg(regmodel.CTRL,     32'h0000_0005);
    // wait past the timeout: load*(presc+1) ticks + margin
    wait_cycles((load_val + 4) * (presc_val + 1) + 6);
    // STATUS.IRQ must be set
    check_reg(regmodel.STATUS, 32'h1, 32'h1);
    // one-shot: EN auto-cleared, IRQ_EN still set  (0b100)
    check_reg(regmodel.CTRL, 32'h0000_0004, 32'h0000_0007);
    // W1C clear
    write_reg(regmodel.STATUS, 32'h1);
    check_reg(regmodel.STATUS, 32'h0, 32'h1);
    // irq should have dropped; give it a couple cycles
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Periodic : verify N consecutive timeouts, clearing STATUS each time.
class apb_timer_periodic_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_periodic_vseq)

  rand int unsigned n_periods;
  rand bit [31:0]   load_val;
  rand bit [7:0]    presc_val;
  constraint c_bounded {
    n_periods inside {[2:4]};
    load_val  inside {[2:6]};
    presc_val inside {[0:2]};
  }

  function new(string name = "apb_timer_periodic_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();
    write_reg(regmodel.PRESCALE, presc_val);
    write_reg(regmodel.LOAD,     load_val);
    // EN=1, MODE=1 (periodic), IRQ_EN=1 -> 0b111
    write_reg(regmodel.CTRL, 32'h0000_0007);
    repeat (n_periods) begin
      wait_cycles(load_val * (presc_val + 1) + 4);
      check_reg(regmodel.STATUS, 32'h1, 32'h1);   // fired
      check_reg(regmodel.CTRL,   32'h0000_0007, 32'h0000_0007); // still enabled
      write_reg(regmodel.STATUS, 32'h1);          // clear for next period
    end
    // stop
    write_reg(regmodel.CTRL, 32'h0);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// Prescale : exercise PRESCALE>0 timeout latency (one-shot).
class apb_timer_prescale_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_prescale_vseq)
  function new(string name = "apb_timer_prescale_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();
    write_reg(regmodel.PRESCALE, 32'h0000_0004);  // divide by 5
    write_reg(regmodel.LOAD,     32'h0000_0003);  // 3 ticks -> 15 cycles
    write_reg(regmodel.CTRL,     32'h0000_0005);  // EN, one-shot, IRQ_EN
    wait_cycles(3 * 5 + 8);
    check_reg(regmodel.STATUS, 32'h1, 32'h1);
    check_reg(regmodel.CTRL,   32'h0000_0004, 32'h0000_0007); // EN cleared
    write_reg(regmodel.STATUS, 32'h1);
    wait_cycles(4);
  endtask
endclass

// ---------------------------------------------------------------------------
// W1C : write-1-to-clear semantics + HW-set-wins race.
class apb_timer_w1c_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_w1c_vseq)
  function new(string name = "apb_timer_w1c_vseq"); super.new(name); endfunction

  task body();
    regmodel.reset();
    // 1) create a set STATUS.IRQ via a one-shot timeout (IRQ_EN=0 to keep irq low)
    write_reg(regmodel.PRESCALE, 32'h0);
    write_reg(regmodel.LOAD,     32'h1);
    write_reg(regmodel.CTRL,     32'h0000_0001);  // EN only, one-shot, IRQ_EN=0
    wait_cycles(8);
    check_reg(regmodel.STATUS, 32'h1, 32'h1);
    // 2) writing 0 must NOT clear (W1C)
    write_reg(regmodel.STATUS, 32'h0);
    check_reg(regmodel.STATUS, 32'h1, 32'h1);
    // 3) writing 1 clears
    write_reg(regmodel.STATUS, 32'h1);
    check_reg(regmodel.STATUS, 32'h0, 32'h1);

    // 4) HW-set-wins race: periodic timeout every cycle (LOAD=0, PRESCALE=0),
    //    hammer STATUS with W1C writes; some coincide with the HW set and the
    //    flag stays set (checked exactly by the SVA/ref model; covered by cg_evt).
    write_reg(regmodel.LOAD, 32'h0);
    write_reg(regmodel.CTRL, 32'h0000_0003);      // EN, periodic
    repeat (12) begin
      write_reg(regmodel.STATUS, 32'h1);          // attempt W1C while HW sets
    end
    write_reg(regmodel.CTRL, 32'h0);              // stop
    write_reg(regmodel.STATUS, 32'h1);            // final clear (no more HW set)
    wait_cycles(4);
    check_reg(regmodel.STATUS, 32'h0, 32'h1);
  endtask
endclass

// ---------------------------------------------------------------------------
// Error : unmapped / unaligned accesses must raise pslverr; RO write must not.
class apb_timer_error_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_error_vseq)
  function new(string name = "apb_timer_error_vseq"); super.new(name); endfunction

  task body();
    apb_seq_item it;
    // unmapped read
    raw_access(APB_READ, 8'h14, 32'h0, it);
    if (!it.slverr || (it.rdata !== 32'h0))
      `uvm_error("ERR_VSEQ", $sformatf("unmapped read: slverr=%0b rdata=0x%08h",
                 it.slverr, it.rdata))
    // unaligned read (0x03)
    raw_access(APB_READ, 8'h03, 32'h0, it);
    if (!it.slverr)
      `uvm_error("ERR_VSEQ", "unaligned read did not raise pslverr")
    // unmapped write
    raw_access(APB_WRITE, 8'h20, 32'hDEAD_BEEF, it);
    if (!it.slverr)
      `uvm_error("ERR_VSEQ", "unmapped write did not raise pslverr")
    // legal write to RO VALUE : NO pslverr, no effect
    raw_access(APB_WRITE, 8'h08, 32'h1234_5678, it);
    if (it.slverr)
      `uvm_error("ERR_VSEQ", "RO VALUE write raised pslverr (should not)")
    // VALUE still 0
    raw_access(APB_READ, 8'h08, 32'h0, it);
    if (it.rdata !== 32'h0)
      `uvm_error("ERR_VSEQ", $sformatf("RO VALUE changed: 0x%08h", it.rdata))
  endtask
endclass

// ---------------------------------------------------------------------------
// RAL showcase : run the built-in hw-reset and bit-bash register sequences.
class apb_timer_reg_hw_reset_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_reg_hw_reset_vseq)
  function new(string name = "apb_timer_reg_hw_reset_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_hw_reset_seq hw;
    uvm_reg_bit_bash_seq bb;

    regmodel.reset();

    hw = uvm_reg_hw_reset_seq::type_id::create("hw");
    hw.model = regmodel;
    hw.start(null);

    // CTRL.EN self-clears / starts counting -> exclude CTRL from bit-bash to
    // avoid false mismatches; VALUE is RO (skipped), STATUS W1C is bashed safely
    // (EN=0 -> no HW set).
    uvm_resource_db#(bit)::set({"REG::", regmodel.CTRL.get_full_name()},
                               "NO_REG_BIT_BASH_TEST", 1, this);

    bb = uvm_reg_bit_bash_seq::type_id::create("bb");
    bb.model = regmodel;
    bb.start(null);
  endtask
endclass

// ---------------------------------------------------------------------------
// Random : randomized legal register traffic + occasional enable/timeout.
class apb_timer_rand_vseq extends apb_timer_base_vseq;
  `uvm_object_utils(apb_timer_rand_vseq)

  rand int unsigned n_ops;
  constraint c_n { n_ops inside {[10:20]}; }

  function new(string name = "apb_timer_rand_vseq"); super.new(name); endfunction

  task body();
    uvm_reg_data_t d;
    regmodel.reset();
    repeat (n_ops) begin
      int unsigned sel = $urandom_range(0, 6);
      case (sel)
        0: write_reg(regmodel.LOAD,     $urandom_range(0, 12));
        1: write_reg(regmodel.PRESCALE, $urandom_range(0, 5));
        2: write_reg(regmodel.CTRL,     $urandom_range(0, 7));
        3: read_reg (regmodel.VALUE,    d);
        4: read_reg (regmodel.STATUS,   d);
        5: begin
             // program a short one-shot and let it run
             write_reg(regmodel.PRESCALE, $urandom_range(0, 2));
             write_reg(regmodel.LOAD,     $urandom_range(1, 5));
             write_reg(regmodel.CTRL,     32'h0000_0005);
             wait_cycles($urandom_range(6, 20));
             write_reg(regmodel.STATUS,   32'h1);
           end
        6: begin
             read_reg(regmodel.CTRL, d);
             wait_cycles($urandom_range(1, 4));
           end
        default: ;
      endcase
    end
    // stop any counting
    write_reg(regmodel.CTRL, 32'h0);
    wait_cycles(6);
  endtask
endclass

`endif // APB_TIMER_VSEQ_LIB_SVH
