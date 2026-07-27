// -----------------------------------------------------------------------------
// photonic_ring_tuner_reg_block.svh : UVM RAL model for the register map (spec 2)
//
//   Registers (byte offsets, 32-bit, little-endian, base 0x0):
//     0x00 CTRL     RW    : EN[0]                                reset 0x0000_0000
//     0x04 STEP     RW    : DITHER[7:0], SWEEP[15:8]             reset 0x0000_2004
//     0x08 SETTLE   RW    : VAL[15:0]                            reset 0x0000_0020
//     0x0C LOCK_CFG RW    : THRESH[15:0], MINPOW[31:16]          reset 0x0100_0008
//     0x10 STATUS   mixed : LOCKED[0] RO, RAIL_ERR[1] W1C,
//                           SWEEP_ERR[2] W1C, ACTIVE[3] RO       reset 0x0000_0000
//     0x14 DAC      RO    : VAL[11:0] = dac_q       (volatile)   reset 0x0000_0000
//     0x18 PD       RO    : VAL[11:0] = pd_q        (volatile)   reset 0x0000_0000
//
//   STEP and LOCK_CFG are deliberately MULTI-FIELD (two independently
//   programmable fields packed in one word) and STATUS mixes access types WITHIN
//   one register -- LOCKED/ACTIVE are read-only live hardware state while
//   RAIL_ERR/SWEEP_ERR are sticky W1C error flags. That is what real silicon
//   looks like and it exercises per-FIELD RAL access policies rather than
//   per-register ones.
//
//   STATUS / DAC / PD are hardware-updated, so neither a walking-ones
//   write/read-back nor a reset-value compare models them. All three are
//   excluded from the automated bit-bash AND hw-reset sequences
//   (NO_REG_BIT_BASH_TEST, spec 6, plus NO_REG_HW_RESET_TEST), and the live
//   fields inside them (STATUS.LOCKED, STATUS.ACTIVE, DAC.VAL, PD.VAL) are
//   additionally set_compare(UVM_NO_CHECK) so that ANY mirror(UVM_CHECK) is
//   correct by construction rather than by the loop happening to be idle. Their
//   real behaviour is checked by the scoreboard against the optical model, and
//   their reset values directly by smoke_vseq.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_REG_BLOCK_SVH
`define PHOTONIC_RING_TUNER_REG_BLOCK_SVH

// ---- CTRL (0x00, RW) --------------------------------------------------------
class photonic_ring_tuner_ctrl_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_ctrl_reg)

  rand uvm_reg_field EN;
       uvm_reg_field RSVD;

  function new(string name = "photonic_ring_tuner_ctrl_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    EN   = uvm_reg_field::type_id::create("EN");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    // configure(parent,size,lsb,access,volatile,reset,has_reset,is_rand,indiv_acc)
    EN.configure  (this,  1, 0, "RW", 0,  1'h0, 1, 1, 0);
    RSVD.configure(this, 31, 1, "RO", 0, 31'h0, 1, 0, 0);
  endfunction
endclass

// ---- STEP (0x04, RW, two fields) --------------------------------------------
class photonic_ring_tuner_step_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_step_reg)

  rand uvm_reg_field DITHER;
  rand uvm_reg_field SWEEP;
       uvm_reg_field RSVD;

  function new(string name = "photonic_ring_tuner_step_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DITHER = uvm_reg_field::type_id::create("DITHER");
    SWEEP  = uvm_reg_field::type_id::create("SWEEP");
    RSVD   = uvm_reg_field::type_id::create("RSVD");
    // Reset 0x0000_2004 -> DITHER = 0x04, SWEEP = 0x20. A programmed 0 reads
    // back as 0; the CLAMP to 1 (spec 2) is hardware-internal and therefore not
    // modelled by the mirror.
    DITHER.configure(this,  8,  0, "RW", 0,  8'h04, 1, 1, 0);
    SWEEP.configure (this,  8,  8, "RW", 0,  8'h20, 1, 1, 0);
    RSVD.configure  (this, 16, 16, "RO", 0, 16'h0,  1, 0, 0);
  endfunction
endclass

// ---- SETTLE (0x08, RW) ------------------------------------------------------
class photonic_ring_tuner_settle_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_settle_reg)

  rand uvm_reg_field VAL;
       uvm_reg_field RSVD;

  function new(string name = "photonic_ring_tuner_settle_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    VAL.configure (this, 16,  0, "RW", 0, 16'h0020, 1, 1, 0);
    RSVD.configure(this, 16, 16, "RO", 0, 16'h0,    1, 0, 0);
  endfunction
endclass

// ---- LOCK_CFG (0x0C, RW, two fields) ----------------------------------------
class photonic_ring_tuner_lock_cfg_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_lock_cfg_reg)

  rand uvm_reg_field THRESH;
  rand uvm_reg_field MINPOW;

  function new(string name = "photonic_ring_tuner_lock_cfg_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    THRESH = uvm_reg_field::type_id::create("THRESH");
    MINPOW = uvm_reg_field::type_id::create("MINPOW");
    // Reset 0x0100_0008 -> THRESH = 0x0008, MINPOW = 0x0100.
    THRESH.configure(this, 16,  0, "RW", 0, 16'h0008, 1, 1, 0);
    MINPOW.configure(this, 16, 16, "RW", 0, 16'h0100, 1, 1, 0);
  endfunction
endclass

// ---- STATUS (0x10, MIXED per field, volatile) -------------------------------
class photonic_ring_tuner_status_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_status_reg)

       uvm_reg_field LOCKED;      // RO  : live loop status (not sticky)
  rand uvm_reg_field RAIL_ERR;    // W1C : sticky, HW-set-wins on a race
  rand uvm_reg_field SWEEP_ERR;   // W1C : sticky, HW-set-wins on a race
       uvm_reg_field ACTIVE;      // RO  : FSM not in S_IDLE
       uvm_reg_field RSVD;

  function new(string name = "photonic_ring_tuner_status_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    LOCKED    = uvm_reg_field::type_id::create("LOCKED");
    RAIL_ERR  = uvm_reg_field::type_id::create("RAIL_ERR");
    SWEEP_ERR = uvm_reg_field::type_id::create("SWEEP_ERR");
    ACTIVE    = uvm_reg_field::type_id::create("ACTIVE");
    RSVD      = uvm_reg_field::type_id::create("RSVD");
    // All four live bits are volatile: hardware drives them behind the mirror's
    // back, so the mirror is informational and the scoreboard owns the truth.
    LOCKED.configure   (this,  1, 0, "RO",  1,  1'h0, 1, 0, 0);
    RAIL_ERR.configure (this,  1, 1, "W1C", 1,  1'h0, 1, 1, 0);
    SWEEP_ERR.configure(this,  1, 2, "W1C", 1,  1'h0, 1, 1, 0);
    ACTIVE.configure   (this,  1, 3, "RO",  1,  1'h0, 1, 0, 0);
    RSVD.configure     (this, 28, 4, "RO",  0, 28'h0, 1, 0, 0);
    // LOCKED and ACTIVE are LIVE hardware state: their value at any read is a
    // property of the optical loop, not of anything the mirror knows. Telling
    // the RAL not to compare them makes every mirror(UVM_CHECK) -- including
    // uvm_reg_hw_reset_seq's -- correct BY CONSTRUCTION rather than correct
    // because the loop happened to be idle when the sequence ran. The two W1C
    // error flags stay comparable: they are sticky, so the mirror can and
    // should track them.
    LOCKED.set_compare(UVM_NO_CHECK);
    ACTIVE.set_compare(UVM_NO_CHECK);
  endfunction
endclass

// ---- DAC (0x14, RO, volatile) -----------------------------------------------
class photonic_ring_tuner_dac_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_dac_reg)

  uvm_reg_field VAL;
  uvm_reg_field RSVD;

  function new(string name = "photonic_ring_tuner_dac_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    // DAC_WIDTH = 12 (the DUT's default parameterization, matched by the tb).
    VAL.configure (this, 12,  0, "RO", 1, 12'h0, 1, 0, 0);
    RSVD.configure(this, 20, 12, "RO", 0, 20'h0, 1, 0, 0);
    // dac_q is live hardware state (spec 3.1: it even HOLDS its bias while the
    // loop is disabled), so the mirror must never be compared against it.
    VAL.set_compare(UVM_NO_CHECK);
  endfunction
endclass

// ---- PD (0x18, RO, volatile) ------------------------------------------------
class photonic_ring_tuner_pd_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_pd_reg)

  uvm_reg_field VAL;
  uvm_reg_field RSVD;

  function new(string name = "photonic_ring_tuner_pd_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    // ADC_WIDTH = 12 (the DUT's default parameterization, matched by the tb).
    VAL.configure (this, 12,  0, "RO", 1, 12'h0, 1, 0, 0);
    RSVD.configure(this, 20, 12, "RO", 0, 20'h0, 1, 0, 0);
    // pd_q is reloaded from adc_code in EVERY sample state (spec 2) -- the most
    // volatile field in the map. Never compare the mirror against it.
    VAL.set_compare(UVM_NO_CHECK);
  endfunction
endclass

// ---- Register block ---------------------------------------------------------
class photonic_ring_tuner_reg_block extends uvm_reg_block;
  `uvm_object_utils(photonic_ring_tuner_reg_block)

  rand photonic_ring_tuner_ctrl_reg     CTRL;
  rand photonic_ring_tuner_step_reg     STEP;
  rand photonic_ring_tuner_settle_reg   SETTLE;
  rand photonic_ring_tuner_lock_cfg_reg LOCK_CFG;
       photonic_ring_tuner_status_reg   STATUS;
       photonic_ring_tuner_dac_reg      DAC;
       photonic_ring_tuner_pd_reg       PD;

  uvm_reg_map default_map;

  function new(string name = "photonic_ring_tuner_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    // ---- create + build the registers ----
    CTRL = photonic_ring_tuner_ctrl_reg::type_id::create("CTRL");
    CTRL.configure(this);
    CTRL.build();

    STEP = photonic_ring_tuner_step_reg::type_id::create("STEP");
    STEP.configure(this);
    STEP.build();

    SETTLE = photonic_ring_tuner_settle_reg::type_id::create("SETTLE");
    SETTLE.configure(this);
    SETTLE.build();

    LOCK_CFG = photonic_ring_tuner_lock_cfg_reg::type_id::create("LOCK_CFG");
    LOCK_CFG.configure(this);
    LOCK_CFG.build();

    STATUS = photonic_ring_tuner_status_reg::type_id::create("STATUS");
    STATUS.configure(this);
    STATUS.build();

    DAC = photonic_ring_tuner_dac_reg::type_id::create("DAC");
    DAC.configure(this);
    DAC.build();

    PD = photonic_ring_tuner_pd_reg::type_id::create("PD");
    PD.configure(this);
    PD.build();

    // Exclude the hardware-updated registers from the automated bit-bash test
    // (spec 6): STATUS is per-field mixed RO/W1C driven by the FSM, DAC mirrors
    // the live dac_q and PD the live pd_q. A walking-ones write/read-back models
    // none of them; the scoreboard checks their true behaviour instead.
    //
    // uvm_reg_bit_bash_seq reads this exclusion from the RESOURCE DB in the
    // "REG::" namespace (uvm_resource_db#(bit)::get_by_name). uvm_reg has no
    // attribute API in UVM 1.2, so set_attribute() must not be used here.
    uvm_resource_db#(bit)::set({"REG::", STATUS.get_full_name()},
                               "NO_REG_BIT_BASH_TEST", 1);
    uvm_resource_db#(bit)::set({"REG::", DAC.get_full_name()},
                               "NO_REG_BIT_BASH_TEST", 1);
    uvm_resource_db#(bit)::set({"REG::", PD.get_full_name()},
                               "NO_REG_BIT_BASH_TEST", 1);

    // Same three registers, same reason, for the hw-reset sequence: it reads
    // every register and compares against the reset value, and all three are
    // driven by the FSM. Today they happen to read 0 there only because the
    // loop is idle when reg_vseq runs -- which is luck, not a contract, and
    // reg_vseq DOES momentarily set CTRL.EN (uvm_reg_bit_bash_seq bashes CTRL).
    // Excluding them makes uvm_reg_hw_reset_seq correct by construction; their
    // reset values are checked directly, and deterministically, by smoke_vseq.
    uvm_resource_db#(bit)::set({"REG::", STATUS.get_full_name()},
                               "NO_REG_HW_RESET_TEST", 1);
    uvm_resource_db#(bit)::set({"REG::", DAC.get_full_name()},
                               "NO_REG_HW_RESET_TEST", 1);
    uvm_resource_db#(bit)::set({"REG::", PD.get_full_name()},
                               "NO_REG_HW_RESET_TEST", 1);

    // ---- address map : base 0x0, 4 bytes/word, byte-addressed, little-endian
    default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);
    default_map.add_reg(CTRL,     'h00, "RW");
    default_map.add_reg(STEP,     'h04, "RW");
    default_map.add_reg(SETTLE,   'h08, "RW");
    default_map.add_reg(LOCK_CFG, 'h0C, "RW");
    default_map.add_reg(STATUS,   'h10, "RW");
    default_map.add_reg(DAC,      'h14, "RO");
    default_map.add_reg(PD,       'h18, "RO");

    lock_model();
  endfunction
endclass

`endif // PHOTONIC_RING_TUNER_REG_BLOCK_SVH
