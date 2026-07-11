// -----------------------------------------------------------------------------
// apb_sequencer.svh : plain sequencer for apb_seq_item.
//   Kept as a named subclass (rather than a bare typedef) so tests/RAL adapters
//   have a concrete type to target and factory-override if ever needed.
// -----------------------------------------------------------------------------
`ifndef APB_SEQUENCER_SVH
`define APB_SEQUENCER_SVH

class apb_sequencer extends uvm_sequencer #(apb_seq_item);
  `uvm_component_utils(apb_sequencer)
  function new(string name="apb_sequencer", uvm_component parent=null);
    super.new(name, parent);
  endfunction
endclass

`endif // APB_SEQUENCER_SVH
