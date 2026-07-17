// -----------------------------------------------------------------------------
// apb_coverage.svh : protocol-level functional coverage for the APB VIP.
//   Subscribes to the monitor's analysis port and samples every observed
//   transaction. Kept generic/reusable and DESIGN-AGNOSTIC (the VIP knows
//   nothing about any IP's register names); the IP env layers its own
//   register-map coverage on top.
//
//   cp_addr bins the low register window (the part every APB peripheral
//   actually decodes) and sends everything above it to a `default` bin. Per
//   IEEE 1800 19.5.4 a default bin is EXCLUDED from the coverage computation,
//   so address space that a given IP never drives cannot hold this shared
//   covergroup's score hostage. Binning the whole bus width instead (e.g.
//   auto_bin_max) would leave most bins permanently empty in every IP env.
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
    // item.addr is [APB_ADDR_WIDTH-1:0] (8 in the timer/gpio builds, 12 in the
    // subsystem build): 'h1F fits in both, so these bins are width-safe.
    cp_addr : coverpoint item.addr {
      bins reg_win[8] = {[0:'h1F]};  // typical peripheral register window
      bins other      = default;     // excluded from the coverage computation
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
