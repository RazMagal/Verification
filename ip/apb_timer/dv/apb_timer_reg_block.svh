// -----------------------------------------------------------------------------
// apb_timer_reg_block.svh : UVM RAL model for the apb_timer register map (spec 2)
//
//   Registers (byte offsets, APB_TIMER_DATA_WIDTH-bit, little-endian, base 0x0):
//     0x00 CTRL     RW   : EN[0], MODE[1], IRQ_EN[2], reserved[DATA-1:3] RO
//     0x04 LOAD     RW   : LOAD[DATA-1:0]
//     0x08 VALUE    RO   : VALUE[DATA-1:0]      (volatile - live HW counter)
//     0x0C STATUS   RW1C : IRQ[0] W1C, reserved[DATA-1:1] RO (volatile - HW sets)
//     0x10 PRESCALE RW   : PRESCALE[PRESC-1:0], reserved[DATA-1:PRESC] RO
//
//   Every width comes from apb_timer_params.svh. The RESERVED fields are the
//   dangerous ones - a stale literal 29/31/24 would silently overlap a real
//   field or leave a hole once the data width moves - so they are stated as
//   "the rest of the register": width = DATA_WIDTH - lsb, lsb = the flag count
//   (CTRL) / the PRESCALE field width. With the defaults this is still 29@3,
//   31@1 and 24@8, bit for bit.
//
//   All reset values are 0. Access policies are exactly the spec's. VALUE and
//   STATUS.IRQ are volatile (HW updated); their mirror is maintained by an
//   explicit uvm_reg_predictor and the true check lives in the reference-model
//   scoreboard, not the mirror.
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_REG_BLOCK_SVH
`define APB_TIMER_REG_BLOCK_SVH

// ---- CTRL (0x00, RW) --------------------------------------------------------
class apb_timer_ctrl_reg extends uvm_reg;
  `uvm_object_utils(apb_timer_ctrl_reg)

  rand uvm_reg_field EN;
  rand uvm_reg_field MODE;
  rand uvm_reg_field IRQ_EN;
       uvm_reg_field RSVD;

  function new(string name = "apb_timer_ctrl_reg");
    super.new(name, APB_TIMER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    EN     = uvm_reg_field::type_id::create("EN");
    MODE   = uvm_reg_field::type_id::create("MODE");
    IRQ_EN = uvm_reg_field::type_id::create("IRQ_EN");
    RSVD   = uvm_reg_field::type_id::create("RSVD");
    // configure(parent,size,lsb,access,volatile,reset,has_reset,is_rand,indiv_acc)
    // Flags occupy the low APB_TIMER_CTRL_FLAGS bits (spec 2.1); RSVD is
    // everything above them, so the two can never overlap or leave a hole.
    EN.configure    (this, 1, 0, "RW", 0, APB_TIMER_REG_RESET, 1, 1, 0);
    MODE.configure  (this, 1, 1, "RW", 0, APB_TIMER_REG_RESET, 1, 1, 0);
    IRQ_EN.configure(this, 1, 2, "RW", 0, APB_TIMER_REG_RESET, 1, 1, 0);
    RSVD.configure  (this, APB_TIMER_CTRL_RSVD_WIDTH, APB_TIMER_CTRL_RSVD_LSB,
                     "RO", 0, APB_TIMER_REG_RESET, 1, 0, 0);
  endfunction
endclass

// ---- LOAD (0x04, RW) --------------------------------------------------------
class apb_timer_load_reg extends uvm_reg;
  `uvm_object_utils(apb_timer_load_reg)

  rand uvm_reg_field VAL;

  function new(string name = "apb_timer_load_reg");
    super.new(name, APB_TIMER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    VAL.configure(this, APB_TIMER_DATA_WIDTH, 0, "RW", 0,
                  APB_TIMER_REG_RESET, 1, 1, 0);
  endfunction
endclass

// ---- VALUE (0x08, RO, volatile) ---------------------------------------------
class apb_timer_value_reg extends uvm_reg;
  `uvm_object_utils(apb_timer_value_reg)

  uvm_reg_field VAL;

  function new(string name = "apb_timer_value_reg");
    super.new(name, APB_TIMER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    // volatile=1 : HW updates this live; RO from the bus.
    VAL.configure(this, APB_TIMER_DATA_WIDTH, 0, "RO", 1,
                  APB_TIMER_REG_RESET, 1, 0, 0);
  endfunction
endclass

// ---- STATUS (0x0C, RW1C, volatile) ------------------------------------------
class apb_timer_status_reg extends uvm_reg;
  `uvm_object_utils(apb_timer_status_reg)

  rand uvm_reg_field IRQ;
       uvm_reg_field RSVD;

  function new(string name = "apb_timer_status_reg");
    super.new(name, APB_TIMER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    IRQ  = uvm_reg_field::type_id::create("IRQ");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    // W1C, volatile (HW set on timeout).
    IRQ.configure (this, 1, 0, "W1C", 1, APB_TIMER_REG_RESET, 1, 1, 0);
    RSVD.configure(this, APB_TIMER_STATUS_RSVD_WIDTH, APB_TIMER_STATUS_RSVD_LSB,
                   "RO", 0, APB_TIMER_REG_RESET, 1, 0, 0);
  endfunction
endclass

// ---- PRESCALE (0x10, RW) ----------------------------------------------------
class apb_timer_prescale_reg extends uvm_reg;
  `uvm_object_utils(apb_timer_prescale_reg)

  rand uvm_reg_field VAL;
       uvm_reg_field RSVD;

  function new(string name = "apb_timer_prescale_reg");
    super.new(name, APB_TIMER_DATA_WIDTH, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL  = uvm_reg_field::type_id::create("VAL");
    RSVD = uvm_reg_field::type_id::create("RSVD");
    VAL.configure (this, APB_TIMER_PRESCALE_WIDTH, 0, "RW", 0,
                   APB_TIMER_REG_RESET, 1, 1, 0);
    RSVD.configure(this, APB_TIMER_PRESC_RSVD_WIDTH, APB_TIMER_PRESC_RSVD_LSB,
                   "RO", 0, APB_TIMER_REG_RESET, 1, 0, 0);
  endfunction
endclass

// ---- Register block ---------------------------------------------------------
class apb_timer_reg_block extends uvm_reg_block;
  `uvm_object_utils(apb_timer_reg_block)

  rand apb_timer_ctrl_reg     CTRL;
  rand apb_timer_load_reg     LOAD;
       apb_timer_value_reg    VALUE;
       apb_timer_status_reg   STATUS;
  rand apb_timer_prescale_reg PRESCALE;

  uvm_reg_map default_map;

  function new(string name = "apb_timer_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    // ---- create + build the registers ----
    CTRL = apb_timer_ctrl_reg::type_id::create("CTRL");
    CTRL.configure(this);
    CTRL.build();

    LOAD = apb_timer_load_reg::type_id::create("LOAD");
    LOAD.configure(this);
    LOAD.build();

    VALUE = apb_timer_value_reg::type_id::create("VALUE");
    VALUE.configure(this);
    VALUE.build();

    STATUS = apb_timer_status_reg::type_id::create("STATUS");
    STATUS.configure(this);
    STATUS.build();

    PRESCALE = apb_timer_prescale_reg::type_id::create("PRESCALE");
    PRESCALE.configure(this);
    PRESCALE.build();

    // Exclude the volatile / HW-updated registers from the automated bit-bash
    // test: VALUE is a RO live counter and STATUS.IRQ is W1C set by hardware,
    // so a walking-ones write/read-back does not model them. Their real behavior
    // is checked by the reference-model scoreboard instead.
    //
    // uvm_reg_bit_bash_seq reads this exclusion from the RESOURCE DB in the
    // "REG::" namespace (uvm_resource_db#(bit)::get_by_name). uvm_reg has no
    // attribute API in UVM 1.2, so set_attribute() must not be used here.
    // configure() above already set each register's parent, so get_full_name()
    // resolves to the correct per-instance hierarchical name (e.g. when this
    // block is reused twice inside the subsystem's hierarchical model).
    uvm_resource_db#(bit)::set({"REG::", VALUE.get_full_name()},
                               "NO_REG_BIT_BASH_TEST", 1);
    uvm_resource_db#(bit)::set({"REG::", STATUS.get_full_name()},
                               "NO_REG_BIT_BASH_TEST", 1);

    // ---- address map : base 0x0, 4 bytes/word, byte-addressed, little-endian
    default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);
    default_map.add_reg(CTRL,     'h00, "RW");
    default_map.add_reg(LOAD,     'h04, "RW");
    default_map.add_reg(VALUE,    'h08, "RO");
    default_map.add_reg(STATUS,   'h0C, "RW");
    default_map.add_reg(PRESCALE, 'h10, "RW");

    lock_model();
  endfunction
endclass

`endif // APB_TIMER_REG_BLOCK_SVH
