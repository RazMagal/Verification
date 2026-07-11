// -----------------------------------------------------------------------------
// apb_seq_item.svh : one APB transfer (request + captured response).
//   The driver turns a single item into a full SETUP->ACCESS transfer, so one
//   item == one register access (this is what lets the RAL adapter map 1:1).
//   Request fields are rand; response fields (rdata/slverr) are filled in by
//   the driver/monitor and are NOT rand.
// -----------------------------------------------------------------------------
`ifndef APB_SEQ_ITEM_SVH
`define APB_SEQ_ITEM_SVH

class apb_seq_item extends uvm_sequence_item;

  // ---- request (stimulus) ----
  rand bit [APB_ADDR_WIDTH-1:0] addr;
  rand apb_dir_e                dir;    // APB_READ / APB_WRITE (== pwrite)
  rand bit [APB_DATA_WIDTH-1:0] wdata;

  // ---- response (captured by driver on the completing beat / by monitor) ----
  bit [APB_DATA_WIDTH-1:0]      rdata;
  bit                           slverr;

  `uvm_object_utils_begin(apb_seq_item)
    `uvm_field_int (addr,   UVM_ALL_ON)
    `uvm_field_enum(apb_dir_e, dir, UVM_ALL_ON)
    `uvm_field_int (wdata,  UVM_ALL_ON)
    `uvm_field_int (rdata,  UVM_ALL_ON)
    `uvm_field_int (slverr, UVM_ALL_ON)
  `uvm_object_utils_end

  // Word-aligned by default. SOFT so error/unaligned sequences can override it.
  constraint c_align { soft addr[1:0] == 2'b00; }

  function new(string name="apb_seq_item");
    super.new(name);
  endfunction

  // Convenience: pwrite view of dir.
  function bit is_write();
    return (dir == APB_WRITE);
  endfunction

  function string convert2string();
    return $sformatf("%-5s addr=0x%0h wdata=0x%0h rdata=0x%0h slverr=%0b",
                     dir.name(), addr, wdata, rdata, slverr);
  endfunction

endclass

`endif // APB_SEQ_ITEM_SVH
