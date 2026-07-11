// -----------------------------------------------------------------------------
// apb_config.svh : per-agent configuration object for the APB master VIP.
//   The tb (or env) creates one and passes it to the agent via config_db under
//   key "apb_config". The agent re-publishes it to its sub-tree so the driver
//   (timeout) and coverage collector (enable) can read it.
// -----------------------------------------------------------------------------
`ifndef APB_CONFIG_SVH
`define APB_CONFIG_SVH

class apb_config extends uvm_object;

  // ACTIVE => build driver + sequencer; PASSIVE => monitor only.
  uvm_active_passive_enum is_active       = UVM_ACTIVE;
  // Driver gives up (uvm_error, no hang) if pready is not seen within this many ns.
  int unsigned            rsp_timeout_ns  = 10000;
  // Enable functional coverage sampling in apb_coverage.
  bit                     coverage_enable = 1'b1;

  `uvm_object_utils_begin(apb_config)
    `uvm_field_enum(uvm_active_passive_enum, is_active,       UVM_ALL_ON)
    `uvm_field_int (rsp_timeout_ns,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int (coverage_enable, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name="apb_config");
    super.new(name);
  endfunction

endclass

`endif // APB_CONFIG_SVH
