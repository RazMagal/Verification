class apb_driver extends uvm_driver #(apb_seq_item);
  `uvm_component_utils(apb_driver);
  
  virtual apb_if.m_drv_mp vif;
  apb_seq_item            seq_it;


  function new(string name="", uvm_component parent=null);
    super.new(name,parent);
  endfunction;


  function void build_phase(uvm_phase phase);
    seq_it = apb_seq_item::type_id::create("seq_it");
    if(!uvm_config_db#(virtual apb_if.m_drv_mp)::get(this, "", "vif", vif))
      `uvm_fatal("NO_VIF", "Can't get virtual if from the database! skill issue");
  endfunction


  task run_phase(uvm_phase phase);
  //  @(posedge vif.rst_n); // wait reset release
    forever begin
      // seq_item_port is defined in base class. get_next_item blocks until the sequencer gives the driver a sequence item:
      seq_item_port.get_next_item(seq_it);
      // Wait for clk posedge and drive all the rest of the signals (Note: this happens in zero time opposed to synchronous rtl where we would sample signals in the previous clock)
      @(vif.m_drv_cb);
      vif.m_drv_cb.paddr   <= seq_it.paddr;
      vif.m_drv_cb.pwrite  <= seq_it.pwrite;
      vif.m_drv_cb.penable <= seq_it.penable;
      vif.m_drv_cb.psel    <= seq_it.psel;
      vif.m_drv_cb.pwdata  <= seq_it.pwdata;
      seq_it.print();
      // complete the handshake with the sequencer
      seq_item_port.item_done();
      // If we're in Access phase, but got no pready, then we keep signals steady until pready has been asserted by thhe slave.
      if (seq_it.wait_for_pready) begin
        // `uvm_info(get_name(), "wait for pready", UVM_LOW);
        wait (vif.m_drv_cb.pready == 1);
      end
    end
  endtask

endclass