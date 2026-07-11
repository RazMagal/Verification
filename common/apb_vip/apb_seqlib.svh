// -----------------------------------------------------------------------------
// apb_seqlib.svh : clean APB master sequence library.
//   One seq_item == one full transfer (the driver does SETUP->ACCESS), so the
//   sequences are simple: build item, set dir/addr/wdata, start/finish.
//   Objections are the TEST's responsibility, not the sequence's.
//   Sequences:
//     apb_base_seq   - p_sequencer + a do_transfer() helper (returns the item)
//     apb_write_seq  - one write (rand addr/wdata)
//     apb_read_seq   - one read  (rand addr; rdata captured in .item)
//     apb_wr_rd_seq  - write then read-back the same address
//     apb_rand_seq   - N randomized legal transfers (N rand, default 10)
// -----------------------------------------------------------------------------
`ifndef APB_SEQLIB_SVH
`define APB_SEQLIB_SVH

// ---------------------------------------------------------------------------
class apb_base_seq extends uvm_sequence #(apb_seq_item);
  `uvm_object_utils(apb_base_seq)
  `uvm_declare_p_sequencer(apb_sequencer)

  function new(string name="apb_base_seq");
    super.new(name);
  endfunction

  // Issue one directed transfer; returns the completed item (with response).
  task do_transfer(input  apb_dir_e                dir,
                   input  bit [APB_ADDR_WIDTH-1:0] addr,
                   input  bit [APB_DATA_WIDTH-1:0] wdata,
                   output apb_seq_item             done);
    apb_seq_item tr = apb_seq_item::type_id::create("tr");
    start_item(tr);
    tr.dir   = dir;
    tr.addr  = addr;
    tr.wdata = wdata;
    finish_item(tr);
    done = tr;
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_write_seq extends apb_base_seq;
  `uvm_object_utils(apb_write_seq)

  rand bit [APB_ADDR_WIDTH-1:0] addr;
  rand bit [APB_DATA_WIDTH-1:0] wdata;
  constraint c_align { soft addr[1:0] == 2'b00; }

  apb_seq_item item;   // completed transfer (for status inspection)

  function new(string name="apb_write_seq");
    super.new(name);
  endfunction

  task body();
    do_transfer(APB_WRITE, addr, wdata, item);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_read_seq extends apb_base_seq;
  `uvm_object_utils(apb_read_seq)

  rand bit [APB_ADDR_WIDTH-1:0] addr;
  constraint c_align { soft addr[1:0] == 2'b00; }

  apb_seq_item item;   // completed transfer; read data is item.rdata

  function new(string name="apb_read_seq");
    super.new(name);
  endfunction

  task body();
    do_transfer(APB_READ, addr, '0, item);
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_wr_rd_seq extends apb_base_seq;
  `uvm_object_utils(apb_wr_rd_seq)

  rand bit [APB_ADDR_WIDTH-1:0] addr;
  rand bit [APB_DATA_WIDTH-1:0] wdata;
  constraint c_align { soft addr[1:0] == 2'b00; }

  apb_seq_item wr_item;
  apb_seq_item rd_item;

  function new(string name="apb_wr_rd_seq");
    super.new(name);
  endfunction

  task body();
    do_transfer(APB_WRITE, addr, wdata, wr_item);
    do_transfer(APB_READ,  addr, '0,    rd_item);
    `uvm_info("APB_WR_RD", $sformatf("addr=0x%0h wrote=0x%0h read=0x%0h slverr=%0b",
              addr, wdata, rd_item.rdata, rd_item.slverr), UVM_MEDIUM)
  endtask
endclass

// ---------------------------------------------------------------------------
class apb_rand_seq extends apb_base_seq;
  `uvm_object_utils(apb_rand_seq)

  rand int unsigned num_xfers;
  constraint c_num { soft num_xfers inside {[1:20]}; }

  function new(string name="apb_rand_seq");
    super.new(name);
    num_xfers = 10;   // default if the sequence object isn't randomized
  endfunction

  task body();
    repeat (num_xfers) begin
      apb_seq_item tr = apb_seq_item::type_id::create("tr");
      start_item(tr);
      if (!tr.randomize())
        `uvm_error("APB_RAND_SEQ", "apb_seq_item randomize() failed")
      finish_item(tr);
    end
  endtask
endclass

`endif // APB_SEQLIB_SVH
