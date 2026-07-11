class apb_env extends uvm_env;
  `uvm_component_utils(apb_env)
  apb_agent agent;
  apb_scoreboard scbd;
  function new(string name="", uvm_component parent=null);
    super.new(name, parent);
  endfunction
  
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = apb_agent::type_id::create("apb_agent", this);
    scbd  = apb_scoreboard::type_id::create("apb_scbd", this);
  endfunction
  
  function void connect_phase(uvm_phase phase);
    agent.mon.mon_analysis_port.connect(scbd.item_collected_export);
  endfunction

endclass