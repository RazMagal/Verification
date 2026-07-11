// -----------------------------------------------------------------------------
// timer_irq_item.svh : one observed irq-line event (a level change).
//   The passive irq monitor emits one item on each irq edge with the new level,
//   the edge polarity (rose/fell) and a cycle stamp for scoreboard alignment.
// -----------------------------------------------------------------------------
`ifndef TIMER_IRQ_ITEM_SVH
`define TIMER_IRQ_ITEM_SVH

class timer_irq_item extends uvm_sequence_item;

  bit          irq;     // new level after the change
  bit          rose;    // 0 -> 1 edge
  bit          fell;    // 1 -> 0 edge
  int unsigned cyc;     // posedge count since t=0 (for expected/actual alignment)
  time         tstamp;  // wall-clock time (informational)

  `uvm_object_utils_begin(timer_irq_item)
    `uvm_field_int(irq,  UVM_ALL_ON)
    `uvm_field_int(rose, UVM_ALL_ON)
    `uvm_field_int(fell, UVM_ALL_ON)
    `uvm_field_int(cyc,  UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "timer_irq_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("irq=%0b rose=%0b fell=%0b cyc=%0d t=%0t",
                     irq, rose, fell, cyc, tstamp);
  endfunction

endclass

`endif // TIMER_IRQ_ITEM_SVH
