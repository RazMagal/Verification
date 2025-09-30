class apb_basic_sequence extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(apb_basic_sequence);
  
  apb_seq_item apb_seq_it;
  
  
  function new(string name="");
    super.new(name);
    apb_seq_it = apb_seq_item::type_id::create("apb_seq_it");
  endfunction : new
  
  task send();
    start_item(apb_seq_it); // Blocking, ask sequncer when is it ready to accept this sequence item
    assert(apb_seq_it.randomize()); // got sequencer attention, randomize
    finish_item(apb_seq_it); // Send to seuqencer
  endtask
  
  task body();
    fork // fork, create a thread on each begin-end. join only when all threads are done
      begin // Thread 1
        send();
      end
    join
  endtask  
endclass


class apb_wr_rd_sequence extends apb_basic_sequence;
  `uvm_object_utils(apb_wr_rd_sequence);
  
  function new(string name="");
    super.new(name);
  endfunction : new

  
  task send_transaction(logic is_write, logic [7:0] addr, logic [31:0] wdata = 0);
     // Using uvm macro to send the seq item with inline constraints using the same sequencer this sequence was started with.
    // Spec summarize for APB3 READ and WRITE. we got three phases:
    // 1. Setup phase:  PSEL is asserted. PADDR, PWRITE and PWDATA are valid.
    `uvm_do_with(apb_seq_it, {
      pwrite          == is_write;
      paddr           == addr;
      pwdata          == wdata;
      psel            == 1;
      penable         == 0; // Setup
      wait_for_pready == 0;
    });
    // 2. Access phase: PENABLE is asserted. PADDR and PWDATA are valid and stable untill DUT asserts pready.
    `uvm_do_with(apb_seq_it, {
      pwrite          == is_write;
      paddr           == addr;
      pwdata          == wdata; // is_write ? wdata : 32'hDEAD_BEEF;
      psel            == 1;
      penable         == 1; // Access
      wait_for_pready == 1;

    });
    // 3. At the end of the transfer, PENABLE is deasserted and so is PSEL (for this basic testbench I don't allow back2back accesses)
    `uvm_do_with(apb_seq_it, {
      // pwdata          == is_write ? wdata : 32'hDEAD_BEEF;
      psel            == 0;
      penable         == 0; // End
      wait_for_pready == 0;
    });
endtask

  
  task body();
    logic [7:0]  addr;
    logic [31:0] data;
    localparam int BYTE_PER_WORD = DATA_WIDTH/8; // 4 for 32-bit data
    
    repeat (5) begin
      addr = ($urandom_range(0, (8'hFC / BYTE_PER_WORD))) * BYTE_PER_WORD;
      data = $urandom;
      
      send_transaction(1, addr, data);
      send_transaction(0, addr, 'hdeadbeef);
    end
  endtask
  
endclass