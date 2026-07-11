// -----------------------------------------------------------------------------
// apb_coverage.svh : protocol-level functional coverage for the APB VIP.
//   Subscribes to the monitor's analysis port and samples every observed
//   transaction. Kept generic/reusable (address is auto-binned across the bus
//   width); the IP env layers its own register-map coverage on top.
// -----------------------------------------------------------------------------
`ifndef APB_COVERAGE_SVH
`define APB_COVERAGE_SVH

class apb_coverage extends uvm_subscriber #(apb_seq_item);
  `uvm_component_utils(apb_coverage)

  apb_config cfg;
  bit        cov_enable = 1'b1;

  covergroup apb_cg with function sample(apb_seq_item item);
    option.per_instance = 1;
    option.name         = "apb_cg";

    cp_dir : coverpoint item.dir {
      bins rd = { APB_READ };
      bins wr = { APB_WRITE };
    }
    cp_addr : coverpoint item.addr {
      option.auto_bin_max = 16;   // width-agnostic buckets across the address space
    }
    cp_slverr : coverpoint item.slverr {
      bins ok  = { 1'b0 };
      bins err = { 1'b1 };
    }
    // did we see both R and W complete OK and error?
    x_dir_slverr : cross cp_dir, cp_slverr;
  endgroup

  function new(string name="apb_coverage", uvm_component parent=null);
    super.new(name, parent);
    apb_cg = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (uvm_config_db#(apb_config)::get(this, "", "apb_config", cfg))
      cov_enable = cfg.coverage_enable;
  endfunction

  // uvm_subscriber write(): sample on every observed transaction.
  virtual function void write(apb_seq_item t);
    if (cov_enable)
      apb_cg.sample(t);
  endfunction

endclass

`endif // APB_COVERAGE_SVH
