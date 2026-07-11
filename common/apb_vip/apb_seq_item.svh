class apb_seq_item extends uvm_sequence_item;
 
  parameter int ADDRESS_WIDTH = 8;
  parameter int DATA_WIDTH    = 32;
  // APB signals
  rand logic [ADDRESS_WIDTH-1:0] paddr;
  rand logic                  pwrite;
  rand logic                  penable;
  rand logic                  psel;
  rand logic [DATA_WIDTH-1:0] pwdata;
  rand logic [DATA_WIDTH-1:0] prdata;
  rand logic                  pready;
  rand logic                  pslverr;
  rand logic                  wait_for_pready; // for ACCESS phase
  
  function new (string name="");
    super.new(name);
  endfunction: new
  // register the seeuence to be able to use factory overrides.
  // register all the fields to be able to use uvm_object methods: copy, compare, pack, unpack, record, print.
  `uvm_object_utils_begin(apb_seq_item)
    `uvm_field_int(paddr, UVM_ALL_ON)
    `uvm_field_int(pwrite, UVM_ALL_ON)
    `uvm_field_int(penable, UVM_ALL_ON)
    `uvm_field_int(psel, UVM_ALL_ON)
    `uvm_field_int(pwdata, UVM_ALL_ON)
  `uvm_object_utils_end
  
  // Constraints
  constraint addr_align_c {
    // word aligned addresses, (DATA_WIDTH/8) LSB are zero's
    // Example: if data width is 32, a.k.a 4 Bytes.
    // And first address is at 0b0000_0000.
    // Then the next accessible address is 0b0000_0100
    // In hex, 1st addr is 0x00. Next addr is 0x04
    // In between 0x00 and 0x04 we have the 2nd, 3rd and 4th Bytes of the Data Word (0b01, 0b10, 0b11 / 0x01, 0x02, 0x03)
    (paddr % (DATA_WIDTH/8)) == 0;
  }

endclass


