class apb_test extends uvm_test;
  `uvm_component_utils(apb_test)

  apb_env  env;
  apb_wr_rd_sequence  seq;
  virtual apb_if vif;
  
  function new(string name = "apb_test",uvm_component parent=null);
    super.new(name,parent);
  endfunction
  
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);       
    env = apb_env::type_id::create("env", this);
    seq = apb_wr_rd_sequence::type_id::create("seq");
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("NO_VIF", "Cannot get vif in test");
  endfunction : build_phase

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait(vif.rst_n==1);
    `uvm_info(get_name(),"starting sequence" ,UVM_LOW);
    seq.start(env.agent.seqr);
    phase.drop_objection(this);
    `uvm_info(get_name(),"test finished" ,UVM_LOW);
  endtask
endclass

