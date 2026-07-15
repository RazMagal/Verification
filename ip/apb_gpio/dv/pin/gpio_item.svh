// -----------------------------------------------------------------------------
// gpio_item.svh : the two pin-agent transactions.
//
//   gpio_item     : STIMULUS consumed by the pin driver/sequencer. It mutates the
//                   driver's shadow of gpio_in with a masked set/clear/toggle or a
//                   full masked drive, then holds for `hold` clocks. Pin vectors
//                   are APB_DATA_WIDTH wide (== NPINS, spec: NPINS = DATA_WIDTH).
//   gpio_mon_item : OBSERVATION emitted by the pin monitor (and predicted by the
//                   reference model) carrying gpio_out/gpio_oe/irq (and gpio_in
//                   for reference) plus a posedge cycle stamp for scoreboard
//                   pairing -- mirrors timer_irq_item.
// -----------------------------------------------------------------------------
`ifndef GPIO_ITEM_SVH
`define GPIO_ITEM_SVH

// Pin-drive operation applied to the driver's gpio_in shadow.
typedef enum bit [1:0] {
  GPIO_DRIVE  = 2'd0,   // gpio_in = (gpio_in & ~mask) | (value & mask)
  GPIO_SET    = 2'd1,   // gpio_in |=  mask
  GPIO_CLEAR  = 2'd2,   // gpio_in &= ~mask
  GPIO_TOGGLE = 2'd3    // gpio_in ^=  mask
} gpio_op_e;

// ---- stimulus item ----------------------------------------------------------
class gpio_item extends uvm_sequence_item;

  rand gpio_op_e                op;
  rand bit [APB_DATA_WIDTH-1:0] mask;
  rand bit [APB_DATA_WIDTH-1:0] value;   // used by GPIO_DRIVE
  rand int unsigned             hold;    // clocks to hold after applying (>=1)

  constraint c_hold { hold inside {[1:4]}; }
  constraint c_mask { soft mask != '0; }  // touch at least one pin by default

  `uvm_object_utils_begin(gpio_item)
    `uvm_field_enum(gpio_op_e, op, UVM_ALL_ON)
    `uvm_field_int (mask,  UVM_ALL_ON)
    `uvm_field_int (value, UVM_ALL_ON)
    `uvm_field_int (hold,  UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "gpio_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%-11s mask=0x%08h value=0x%08h hold=%0d",
                     op.name(), mask, value, hold);
  endfunction
endclass

// ---- observation item -------------------------------------------------------
class gpio_mon_item extends uvm_sequence_item;

  bit [APB_DATA_WIDTH-1:0] gpio_out;
  bit [APB_DATA_WIDTH-1:0] gpio_oe;
  bit                      irq;
  bit [APB_DATA_WIDTH-1:0] gpio_in;   // informational (raw driven pins)
  int unsigned             cyc;       // posedge count since t=0 (for alignment)
  time                     tstamp;

  `uvm_object_utils_begin(gpio_mon_item)
    `uvm_field_int(gpio_out, UVM_ALL_ON)
    `uvm_field_int(gpio_oe,  UVM_ALL_ON)
    `uvm_field_int(irq,      UVM_ALL_ON)
    `uvm_field_int(gpio_in,  UVM_ALL_ON)
    `uvm_field_int(cyc,      UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "gpio_mon_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("out=0x%08h oe=0x%08h irq=%0b in=0x%08h cyc=%0d t=%0t",
                     gpio_out, gpio_oe, irq, gpio_in, cyc, tstamp);
  endfunction
endclass

`endif // GPIO_ITEM_SVH
