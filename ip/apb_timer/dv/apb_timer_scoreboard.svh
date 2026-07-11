class apb_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(apb_scoreboard);
  uvm_analysis_imp #(apb_seq_item, apb_scoreboard) item_collected_export;
  
  // Memory to store transactions
  typedef struct {
    int addr;
    int data;
  } apb_mem_t;
  apb_mem_t write_mem[$]; // dynamic array for writes
  apb_mem_t read_mem[$];  // dynamic array for reads

  
  function new(string name="", uvm_component parent=null);
    super.new(name,parent);
  endfunction
  
  
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    item_collected_export = new("item_collected_export", this);
  endfunction
  
  
  // Receive data from the monitor analysis port
  virtual function void write (apb_seq_item seq);
    // if not a valid ACCESS phase, ignore transaction
    if(!seq.penable || !seq.pready)
      return;
    // valid transaction
    // if write
    if(seq.pwrite) begin
      write_mem.push_back('{seq.paddr, seq.pwdata});
      `uvm_info("APB_WR", $sformatf("Pushed Write data at addr 0x%0h: data=0x%0h", seq.paddr, seq.pwdata), UVM_LOW)
    end
    // valid read:
    else begin
      bit match_found = 0;
      foreach(write_mem[i]) begin
        if(write_mem[i].addr == seq.paddr) begin
          match_found = 1;
          if(write_mem[i].data !== seq.prdata)
            `uvm_error("APB_RD_WR_MISMATCH", $sformatf("Read data mismatch write at addr 0x%0h: read=0x%0h write=0x%0h", seq.paddr, seq.prdata, write_mem[i].data))
          else
            `uvm_info("APB_RD_WR_MATCH", $sformatf("Read data matches Write at addr 0x%0h: data=0x%0h", seq.paddr, write_mem[i].data), UVM_LOW)
          break;
        end
      end
    end
  endfunction
  
endclass