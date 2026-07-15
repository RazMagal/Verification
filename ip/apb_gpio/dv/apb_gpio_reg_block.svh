// -----------------------------------------------------------------------------
// apb_gpio_reg_block.svh : UVM RAL model for the apb_gpio register map (spec 2)
//
//   Registers (byte offsets, 32-bit, little-endian, base 0x0):
//     0x00 DATA_OUT   RW   : value driven onto gpio_out (all pins)
//     0x04 DATA_IN    RO   : synchronized live sample of gpio_in (volatile)
//     0x08 DIR        RW   : per-pin direction / output enable (1=out, 0=in)
//     0x0C INT_STATUS RW1C : per-pin rising-edge flag, sticky (volatile - HW sets)
//     0x10 INT_EN     RW   : per-pin interrupt enable
//
//   All reset values are 0; every bit maps to a pin index. DATA_IN mirrors the
//   external stimulus (volatile RO) and INT_STATUS is HW-set W1C; both are
//   excluded from the automated bit-bash test (NO_REG_BIT_BASH_TEST), exactly as
//   the timer excludes its RO VALUE and W1C STATUS. Their true behaviour is
//   checked by the reference-model scoreboard, not the mirror.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_REG_BLOCK_SVH
`define APB_GPIO_REG_BLOCK_SVH

// ---- DATA_OUT (0x00, RW) ----------------------------------------------------
class apb_gpio_data_out_reg extends uvm_reg;
  `uvm_object_utils(apb_gpio_data_out_reg)

  rand uvm_reg_field VAL;

  function new(string name = "apb_gpio_data_out_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    // configure(parent,size,lsb,access,volatile,reset,has_reset,is_rand,indiv_acc)
    VAL.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
  endfunction
endclass

// ---- DATA_IN (0x04, RO, volatile) -------------------------------------------
class apb_gpio_data_in_reg extends uvm_reg;
  `uvm_object_utils(apb_gpio_data_in_reg)

  uvm_reg_field VAL;

  function new(string name = "apb_gpio_data_in_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    // volatile=1 : HW updates this live from the synchronized pins; RO from bus.
    VAL.configure(this, 32, 0, "RO", 1, 32'h0, 1, 0, 0);
  endfunction
endclass

// ---- DIR (0x08, RW) ---------------------------------------------------------
class apb_gpio_dir_reg extends uvm_reg;
  `uvm_object_utils(apb_gpio_dir_reg)

  rand uvm_reg_field VAL;

  function new(string name = "apb_gpio_dir_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    VAL.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
  endfunction
endclass

// ---- INT_STATUS (0x0C, RW1C, volatile) --------------------------------------
class apb_gpio_int_status_reg extends uvm_reg;
  `uvm_object_utils(apb_gpio_int_status_reg)

  rand uvm_reg_field VAL;

  function new(string name = "apb_gpio_int_status_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    // W1C, volatile (HW sets on a rising edge of din_sync).
    VAL.configure(this, 32, 0, "W1C", 1, 32'h0, 1, 1, 0);
  endfunction
endclass

// ---- INT_EN (0x10, RW) ------------------------------------------------------
class apb_gpio_int_en_reg extends uvm_reg;
  `uvm_object_utils(apb_gpio_int_en_reg)

  rand uvm_reg_field VAL;

  function new(string name = "apb_gpio_int_en_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    VAL = uvm_reg_field::type_id::create("VAL");
    VAL.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
  endfunction
endclass

// ---- Register block ---------------------------------------------------------
class apb_gpio_reg_block extends uvm_reg_block;
  `uvm_object_utils(apb_gpio_reg_block)

  rand apb_gpio_data_out_reg   DATA_OUT;
       apb_gpio_data_in_reg    DATA_IN;
  rand apb_gpio_dir_reg        DIR;
  rand apb_gpio_int_status_reg INT_STATUS;
  rand apb_gpio_int_en_reg     INT_EN;

  uvm_reg_map default_map;

  function new(string name = "apb_gpio_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    // ---- create + build the registers ----
    DATA_OUT = apb_gpio_data_out_reg::type_id::create("DATA_OUT");
    DATA_OUT.configure(this);
    DATA_OUT.build();

    DATA_IN = apb_gpio_data_in_reg::type_id::create("DATA_IN");
    DATA_IN.configure(this);
    DATA_IN.build();

    DIR = apb_gpio_dir_reg::type_id::create("DIR");
    DIR.configure(this);
    DIR.build();

    INT_STATUS = apb_gpio_int_status_reg::type_id::create("INT_STATUS");
    INT_STATUS.configure(this);
    INT_STATUS.build();

    INT_EN = apb_gpio_int_en_reg::type_id::create("INT_EN");
    INT_EN.configure(this);
    INT_EN.build();

    // Exclude the volatile / HW-updated registers from the automated bit-bash
    // test: DATA_IN is a RO live sample of the external pins and INT_STATUS is
    // W1C set by hardware on a rising edge, so a walking-ones write/read-back
    // does not model them. Their real behaviour is checked by the reference-
    // model scoreboard instead.
    DATA_IN.set_attribute   ("NO_REG_BIT_BASH_TEST", "1");
    INT_STATUS.set_attribute("NO_REG_BIT_BASH_TEST", "1");

    // ---- address map : base 0x0, 4 bytes/word, byte-addressed, little-endian
    default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);
    default_map.add_reg(DATA_OUT,   'h00, "RW");
    default_map.add_reg(DATA_IN,    'h04, "RO");
    default_map.add_reg(DIR,        'h08, "RW");
    default_map.add_reg(INT_STATUS, 'h0C, "RW");
    default_map.add_reg(INT_EN,     'h10, "RW");

    lock_model();
  endfunction
endclass

`endif // APB_GPIO_REG_BLOCK_SVH
