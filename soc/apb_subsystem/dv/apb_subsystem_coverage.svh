// -----------------------------------------------------------------------------
// apb_subsystem_coverage.svh : subsystem-level functional coverage.
//   Layered ON TOP of the reused apb_coverage (which the top agent already runs
//   for generic APB dir/addr/slverr). This one is decode-plan focused: which
//   PAGE was targeted (timer0/timer1/mem/unmapped), read vs write, decode-error
//   seen, and the page x error cross (proving every page saw both ok and, where
//   applicable, an error response).
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_COVERAGE_SVH
`define APB_SUBSYSTEM_COVERAGE_SVH

class apb_subsystem_coverage extends uvm_subscriber #(apb_seq_item);
  `uvm_component_utils(apb_subsystem_coverage)

  bit cov_enable = 1'b1;

  covergroup cg_decode with function sample(bit [3:0] page, apb_dir_e dir, bit err);
    option.per_instance = 1;
    option.name         = "cg_decode";

    cp_page : coverpoint page {
      bins timer0   = { 4'h0 };
      bins timer1   = { 4'h1 };
      bins mem      = { 4'h2 };
      bins unmapped = { [4'h3 : 4'hF] };
    }
    cp_dir : coverpoint dir {
      bins rd = { APB_READ };
      bins wr = { APB_WRITE };
    }
    cp_err : coverpoint err {
      bins ok  = { 1'b0 };
      bins err = { 1'b1 };
    }
    x_page_err : cross cp_page, cp_err {
      // Structurally-unreachable combinations: the memory slave never errors,
      // and an unmapped page always errors. Ignore them so the cross can close.
      ignore_bins impossible =
          (binsof(cp_page.mem)      && binsof(cp_err.err)) ||
          (binsof(cp_page.unmapped) && binsof(cp_err.ok));
    }
    x_page_dir : cross cp_page, cp_dir;
  endgroup

  function new(string name = "apb_subsystem_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_decode = new();
  endfunction

  // uvm_subscriber write(): one sample per observed upstream transaction.
  virtual function void write(apb_seq_item t);
    if (!cov_enable) return;
    cg_decode.sample(t.addr[11:8], t.dir, t.slverr);
  endfunction

endclass

`endif // APB_SUBSYSTEM_COVERAGE_SVH
