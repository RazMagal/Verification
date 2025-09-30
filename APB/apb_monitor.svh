class apb_monitor extends uvm_monitor;
  `uvm_component_utils(apb_monitor);
  
  virtual apb_if.m_mon_mp      vif;
  apb_seq_item                 seq_it;
  uvm_analysis_port #(apb_seq_item) mon_analysis_port;
  
  
  function new(string name="", uvm_component parent=null);
    super.new(name,parent);
    mon_analysis_port = new("mon_analysis_port", this);
  endfunction;
  
  function void build_phase(uvm_phase phase);
    seq_it = apb_seq_item::type_id::create("seq_it");
    if(!uvm_config_db#(virtual apb_if.m_mon_mp)::get(this, "", "vif", vif))
      `uvm_fatal("NO_VIF", "Can't get virtual if from the database! skill issue");
  endfunction
  

  task run_phase(uvm_phase phase);
    @(posedge vif.rst_n); // wait reset release
    forever begin
      // Wait for clk posedge and then check if valid transcation on the interface
      @(vif.m_mon_cb);
      // Only track valid transactions:
      if (vif.m_mon_cb.psel && vif.m_mon_cb.penable && vif.m_mon_cb.pready) begin
        seq_it.paddr   = vif.m_mon_cb.paddr;
        seq_it.pwrite  = vif.m_mon_cb.pwrite;
        seq_it.penable = vif.m_mon_cb.penable;
        seq_it.psel    = vif.m_mon_cb.psel;
        seq_it.pwdata  = vif.m_mon_cb.pwdata;
        seq_it.prdata  = vif.m_mon_cb.prdata;
        // Broadcast (one-to-many) seq_item to whomever it may concern (in our case its scoreboard)
        mon_analysis_port.write(seq_it);
      end
    end
  endtask
endclass