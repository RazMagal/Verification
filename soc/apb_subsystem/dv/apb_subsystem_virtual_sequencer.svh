// -----------------------------------------------------------------------------
// apb_subsystem_virtual_sequencer.svh : the subsystem virtual sequencer.
//   Holds the TOP active agent's apb_sequencer handle. All subsystem vseqs run
//   on this vseqr; RAL front-door ops auto-route to the root map's sequencer
//   (this same top_seqr), and raw APB stimulus is started explicitly on it.
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_VIRTUAL_SEQUENCER_SVH
`define APB_SUBSYSTEM_VIRTUAL_SEQUENCER_SVH

class apb_subsystem_virtual_sequencer extends uvm_sequencer;
  `uvm_component_utils(apb_subsystem_virtual_sequencer)

  // Handle to the reused top active agent's sequencer (wired in env connect).
  apb_sequencer top_seqr;

  function new(string name = "apb_subsystem_virtual_sequencer",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // APB_SUBSYSTEM_VIRTUAL_SEQUENCER_SVH
