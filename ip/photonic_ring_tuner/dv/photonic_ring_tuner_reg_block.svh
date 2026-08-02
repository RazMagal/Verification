// -----------------------------------------------------------------------------
// photonic_ring_tuner_reg_block.svh : UVM RAL model for the register map (spec 2)
//
//   Registers (byte offsets, 32-bit, little-endian, base 0x0):
//     0x00 CTRL     RW    : EN[0]                                reset 0x0000_0000
//     0x04 STEP     RW    : DITHER[7:0], SWEEP[15:8]             reset 0x0000_2004
//     0x08 SETTLE   RW    : VAL[15:0]                            reset 0x0000_0020
//     0x0C LOCK_CFG RW    : THRESH[15:0], MINPOW[31:16]
//                           reset {2**(ADC_WIDTH-4), 16'h0008} = 0x0100_0008
//                           at the default ADC_WIDTH = 12
//     0x10 STATUS   mixed : LOCKED[0] RO, RAIL_ERR[1] W1C,
//                           SWEEP_ERR[2] W1C, ACTIVE[3] RO       reset 0x0000_0000
//     0x14 DAC      RO    : VAL[DAC_WIDTH-1:0] = dac_q (volatile) reset 0x0000_0000
//     0x18 PD       RO    : VAL[ADC_WIDTH-1:0] = pd_q  (volatile) reset 0x0000_0000
//
//   WIDTHS ARE NOT WRITTEN DOWN HERE. Every field width, every lsb position and
//   every reserved-padding width below is derived from
//   photonic_ring_tuner_params.svh (TUNER_DAC_WIDTH / TUNER_ADC_WIDTH /
//   TUNER_DATA_WIDTH), which is the same file the tb parameterizes the DUT
//   from. A DAC_WIDTH change therefore moves the DUT and the RAL together
//   instead of leaving a mirror that silently mis-models the hardware.
//
//   The widths that are NOT parameters are the SPEC 2 PACKED-FIELD widths: STEP
//   is two 8-bit fields, SETTLE / LOCK_CFG.THRESH / LOCK_CFG.MINPOW are 16-bit,
//   and STATUS defines four flag bits. Those are register-map facts, not
//   converter geometry, so they are named localparams with the spec reference
//   rather than derived from anything.
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

  localparam int EN_W   = 1;                             // spec 2: CTRL[0]
  localparam int RSVD_W = TUNER_DATA_WIDTH - EN_W;       // 31 @ DATA_WIDTH 32

  function new(string name = "photonic_ring_tuner_ctrl_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    EN   = uvm_reg_field::type_id::create("EN");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    // configure(parent,size,lsb,access,volatile,reset,has_reset,is_rand,indiv_acc)
    EN.configure  (this, EN_W,   0,    "RW", 0, EN_W'(0),   1, 1, 0);
    RSVD.configure(this, RSVD_W, EN_W, "RO", 0, RSVD_W'(0), 1, 0, 0);
  endfunction
endclass

// ---- STEP (0x04, RW, two fields) --------------------------------------------
class photonic_ring_tuner_step_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_step_reg)

  rand uvm_reg_field DITHER;
  rand uvm_reg_field SWEEP;
       uvm_reg_field RSVD;

  // Spec 2: STEP is two 8-bit step sizes in DAC LSBs, DITHER[7:0] SWEEP[15:8].
  // 8 is the REGISTER FIELD width (it bounds the programmable step, and the RTL
  // carries it as STEP_W = 8), not the DAC width, so it is not derived from it.
  localparam int STEP_W = 8;
  localparam int RSVD_W = TUNER_DATA_WIDTH - 2 * STEP_W;   // 16 @ DATA_WIDTH 32

  function new(string name = "photonic_ring_tuner_step_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DITHER = uvm_reg_field::type_id::create("DITHER");
    SWEEP  = uvm_reg_field::type_id::create("SWEEP");
    RSVD   = uvm_reg_field::type_id::create("RSVD");
    // Reset 0x0000_2004 -> DITHER = 0x04, SWEEP = 0x20. A programmed 0 reads
    // back as 0; the CLAMP to 1 (spec 2) is hardware-internal and therefore not
    // modelled by the mirror.
    DITHER.configure(this, STEP_W,     0,          "RW", 0, 8'h04, 1, 1, 0);
    SWEEP.configure (this, STEP_W,     STEP_W,     "RW", 0, 8'h20, 1, 1, 0);
    RSVD.configure  (this, RSVD_W, 2 * STEP_W,     "RO", 0, RSVD_W'(0), 1, 0, 0);
  endfunction
endclass

// ---- SETTLE (0x08, RW) ------------------------------------------------------
class photonic_ring_tuner_settle_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_settle_reg)

  rand uvm_reg_field VAL;
       uvm_reg_field RSVD;

  // Spec 2: SETTLE[15:0] is a CLOCK COUNT, so its 16 bits are a register-map
  // fact with no relation to any converter width.
  localparam int VAL_W  = 16;
  localparam int RSVD_W = TUNER_DATA_WIDTH - VAL_W;        // 16 @ DATA_WIDTH 32

  function new(string name = "photonic_ring_tuner_settle_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    VAL.configure (this, VAL_W,  0,     "RW", 0, 16'h0020,   1, 1, 0);
    RSVD.configure(this, RSVD_W, VAL_W, "RO", 0, RSVD_W'(0), 1, 0, 0);
  endfunction
endclass

// ---- LOCK_CFG (0x0C, RW, two fields) ----------------------------------------
class photonic_ring_tuner_lock_cfg_reg extends uvm_reg;
  `uvm_object_utils(photonic_ring_tuner_lock_cfg_reg)

  rand uvm_reg_field THRESH;
  rand uvm_reg_field MINPOW;

  // Spec 2: THRESH[15:0] and MINPOW[31:16], lock criteria in ADC LSBs. The two
  // 16-bit halves fill the word EXACTLY, which is true only at
  // TUNER_DATA_WIDTH = 32 -- that is precisely the layout that pins DATA_WIDTH
  // (see photonic_ring_tuner_params.svh and the RTL's elaboration $fatal), so
  // there is no reserved field here to derive.
  //
  // The two RESET VALUES are asymmetric on purpose, and neither is written here:
  // MINPOW is compared against pd_q, an ADC code, and is physically a FRACTION
  // of the expected peak, so its reset scales with ADC_WIDTH
  // (TUNER_MINPOW_RST = full-scale/16 = 0x0100 at the default 12 bits); THRESH
  // is judged against the quantization noise floor and is therefore absolute.
  // Both come from photonic_ring_tuner_params.svh, which is also where the
  // reasoning lives -- the DUT computes the same two numbers from the same
  // ADC_WIDTH, so this mirror cannot drift from the hardware.
  localparam int HALF_W = 16;

  function new(string name = "photonic_ring_tuner_lock_cfg_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    THRESH = uvm_reg_field::type_id::create("THRESH");
    MINPOW = uvm_reg_field::type_id::create("MINPOW");
    // Reset TUNER_LOCK_CFG_RST = 0x0100_0008 at the default ADC_WIDTH = 12 ->
    // THRESH = 0x0008 (absolute), MINPOW = 0x0100 (= ADC full-scale/16).
    THRESH.configure(this, HALF_W, 0,      "RW", 0, HALF_W'(TUNER_THRESH_RST), 1, 1, 0);
    MINPOW.configure(this, HALF_W, HALF_W, "RW", 0, HALF_W'(TUNER_MINPOW_RST), 1, 1, 0);
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

  // Spec 2: STATUS defines four flag bits, [3:0]. A flag count, not a width.
  localparam int N_FLAGS = 4;
  localparam int RSVD_W  = TUNER_DATA_WIDTH - N_FLAGS;      // 28 @ DATA_WIDTH 32

  function new(string name = "photonic_ring_tuner_status_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    LOCKED    = uvm_reg_field::type_id::create("LOCKED");
    RAIL_ERR  = uvm_reg_field::type_id::create("RAIL_ERR");
    SWEEP_ERR = uvm_reg_field::type_id::create("SWEEP_ERR");
    ACTIVE    = uvm_reg_field::type_id::create("ACTIVE");
    RSVD      = uvm_reg_field::type_id::create("RSVD");
    // All four live bits are volatile: hardware drives them behind the mirror's
    // back, so the mirror is informational and the scoreboard owns the truth.
    LOCKED.configure   (this, 1,      0,       "RO",  1, 1'h0, 1, 0, 0);
    RAIL_ERR.configure (this, 1,      1,       "W1C", 1, 1'h0, 1, 1, 0);
    SWEEP_ERR.configure(this, 1,      2,       "W1C", 1, 1'h0, 1, 1, 0);
    ACTIVE.configure   (this, 1,      3,       "RO",  1, 1'h0, 1, 0, 0);
    RSVD.configure     (this, RSVD_W, N_FLAGS, "RO",  0, RSVD_W'(0), 1, 0, 0);
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

  // Spec 2: DAC is `[DAC_WIDTH-1:0]`, the rest of the word reserved. BOTH the
  // field and its padding come from the one parameter the tb also gives the
  // DUT, so this mirror cannot go on modelling a 12-bit DAC after someone
  // reparameterizes the hardware.
  localparam int VAL_W  = TUNER_DAC_WIDTH;                 // 12
  localparam int RSVD_W = TUNER_DATA_WIDTH - TUNER_DAC_WIDTH;  // 20

  function new(string name = "photonic_ring_tuner_dac_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    VAL.configure (this, VAL_W,  0,     "RO", 1, VAL_W'(0),  1, 0, 0);
    RSVD.configure(this, RSVD_W, VAL_W, "RO", 0, RSVD_W'(0), 1, 0, 0);
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

  // Spec 2: PD is `[ADC_WIDTH-1:0]`, the rest of the word reserved. Note this
  // one tracks the ADC, not the DAC -- the two parameters are independent even
  // though both default to 12, and writing "12" twice hid that.
  localparam int VAL_W  = TUNER_ADC_WIDTH;                 // 12
  localparam int RSVD_W = TUNER_DATA_WIDTH - TUNER_ADC_WIDTH;  // 20

  function new(string name = "photonic_ring_tuner_pd_reg");
    super.new(name, TUNER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    VAL.configure (this, VAL_W,  0,     "RO", 1, VAL_W'(0),  1, 0, 0);
    RSVD.configure(this, RSVD_W, VAL_W, "RO", 0, RSVD_W'(0), 1, 0, 0);
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

    // ---- address map : base 0x0, DATA_WIDTH/8 bytes per word (4), byte-
    //      addressed, little-endian. The byte offsets themselves are spec-2
    //      register-map facts and stay literal; only the WORD SIZE is a width.
    default_map = create_map("default_map", 'h0, TUNER_DATA_WIDTH / 8,
                             UVM_LITTLE_ENDIAN, 1);
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
