// -----------------------------------------------------------------------------
// apb_reg_adapter.svh : RAL bridge between uvm_reg_bus_op and apb_seq_item.
//   Front-door register access (uvm_reg::read/write) is translated to a single
//   APB transfer on the master agent, and the transfer's response is translated
//   back to a register status/data.
//   supports_byte_enable = 0 : APB has no per-byte strobes in this VIP.
//   provides_responses   = 0 : the driver writes rsp fields back INTO the req
//                              item, so bus2reg reads them from the same object.
// -----------------------------------------------------------------------------
`ifndef APB_REG_ADAPTER_SVH
`define APB_REG_ADAPTER_SVH

class apb_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(apb_reg_adapter)

  function new(string name="apb_reg_adapter");
    super.new(name);
    supports_byte_enable = 0;
    provides_responses   = 0;
  endfunction

  // reg2bus: register op -> APB transfer item.
  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_seq_item item = apb_seq_item::type_id::create("reg2bus_item");
    item.dir   = (rw.kind == UVM_WRITE) ? APB_WRITE : APB_READ;
    item.addr  = rw.addr[APB_ADDR_WIDTH-1:0];
    item.wdata = rw.data[APB_DATA_WIDTH-1:0];
    return item;
  endfunction

  // bus2reg: completed APB transfer -> register op (data + status).
  //   Used both for RAL front-door completion and by uvm_reg_predictor on
  //   monitor-observed transactions (write -> wdata, read -> rdata).
  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    apb_seq_item item;
    if (!$cast(item, bus_item)) begin
      `uvm_fatal("APB_REG_ADAPTER", "bus2reg: bus_item is not an apb_seq_item")
      return;
    end
    rw.kind   = (item.dir == APB_WRITE) ? UVM_WRITE : UVM_READ;
    rw.addr   = item.addr;
    rw.data   = (item.dir == APB_WRITE) ? item.wdata : item.rdata;
    rw.status = item.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction

endclass

`endif // APB_REG_ADAPTER_SVH
