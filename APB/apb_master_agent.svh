
class apb_agent extends uvm_agent;
  `uvm_component_utils(apb_agent)
  apb_driver drv;
  apb_monitor mon;
  apb_sequencer seqr; // usually very basic so typedef is enough
  
  function new(string name="", uvm_component parent=null);
    super.new(name,parent);
  endfunction
  
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Getting instances from the factory (will enable future override without changing the code
    mon = apb_monitor::type_id::create("apb_monitor", this);
    // Built-in uvm_agent variable is_active, either passive or active
    if(get_is_active() == UVM_ACTIVE) begin
      drv = apb_driver::type_id::create("apb_driver", this);
      seqr = apb_sequencer::type_id::create("apb_sequencer", this);
    end
  endfunction
  
  function void connect_phase(uvm_phase phase);
    if(get_is_active() == UVM_ACTIVE) begin
      // Connection of sequencer<->driver seq_item ports
      drv.seq_item_port.connect(seqr.seq_item_export);
      `uvm_info(get_name(), "connected driver <-> sequencer", UVM_LOW)

    end
  endfunction
endclass