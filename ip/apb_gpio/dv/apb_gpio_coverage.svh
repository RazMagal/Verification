// -----------------------------------------------------------------------------
// apb_gpio_coverage.svh : gpio-specific functional coverage (the VIP already
//   covers generic APB dir/addr/slverr). Two analysis inputs:
//     _apb : observed APB transactions (decode register writes + pslverr)
//     _evt : reference-model gpio events (edge detected / irq assert / W1C race)
//
//   Coverage plan hit here:
//     DIR      patterns : all-input / all-output / mixed
//     INT_EN   patterns : none / all / some enabled
//     DATA_OUT activity : zero / all-ones / mixed drive
//     pslverr seen (ok / err)
//     edge detected; irq asserted; W1C-vs-HW-set race observed
//
//   The "all pins" bins use APB_GPIO_PINS_ALL / _NONE (all ones / all zeros of
//   the PIN COUNT, from apb_gpio_params.svh) rather than a literal
//   32'hFFFF_FFFF, so "all outputs" keeps meaning all outputs.
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_COVERAGE_SVH
`define APB_GPIO_COVERAGE_SVH

`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_evt)

class apb_gpio_coverage extends uvm_component;
  `uvm_component_utils(apb_gpio_coverage)

  uvm_analysis_imp_apb #(apb_seq_item,      apb_gpio_coverage) apb_imp;
  uvm_analysis_imp_evt #(apb_gpio_evt_item, apb_gpio_coverage) evt_imp;

  bit cov_enable = 1'b1;

  // Byte offsets are as wide as the bus the monitor reports (apb_seq_item.addr).
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] DATA_OUT_OFF = 'h00;
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] DIR_OFF      = 'h08;
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] INT_EN_OFF   = 'h10;

  // ---- DIR configuration coverage ----
  covergroup cg_dir with function sample(bit [APB_GPIO_NUM_PINS-1:0] d);
    option.per_instance = 1;
    option.name         = "cg_dir";
    cp_dir : coverpoint d {
      bins all_in  = {APB_GPIO_PINS_NONE};
      bins all_out = {APB_GPIO_PINS_ALL};
      bins mixed   = default;
    }
  endgroup

  // ---- INT_EN configuration coverage ----
  covergroup cg_inten with function sample(bit [APB_GPIO_NUM_PINS-1:0] e);
    option.per_instance = 1;
    option.name         = "cg_inten";
    cp_inten : coverpoint e {
      bins none = {APB_GPIO_PINS_NONE};
      bins all  = {APB_GPIO_PINS_ALL};
      bins some = default;
    }
  endgroup

  // ---- DATA_OUT activity coverage ----
  covergroup cg_dout with function sample(bit [APB_GPIO_NUM_PINS-1:0] o);
    option.per_instance = 1;
    option.name         = "cg_dout";
    cp_dout : coverpoint o {
      bins zero     = {APB_GPIO_PINS_NONE};
      bins all_ones = {APB_GPIO_PINS_ALL};
      bins mixed    = default;
    }
  endgroup

  // ---- pslverr coverage ----
  covergroup cg_err with function sample(bit e);
    option.per_instance = 1;
    option.name         = "cg_err";
    cp_slverr : coverpoint e { bins ok = {1'b0}; bins err = {1'b1}; }
  endgroup

  // ---- gpio-event coverage ----
  covergroup cg_evt with function sample(bit edge_det, bit irq_asrt, bit w1c_race);
    option.per_instance = 1;
    option.name         = "cg_evt";
    cp_edge     : coverpoint edge_det  { bins hit = {1'b1}; }
    cp_irq      : coverpoint irq_asrt  { bins hit = {1'b1}; }
    cp_w1c_race : coverpoint w1c_race  { bins hit = {1'b1}; }
  endgroup

  function new(string name = "apb_gpio_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_dir   = new();
    cg_inten = new();
    cg_dout  = new();
    cg_err   = new();
    cg_evt   = new();
    apb_imp  = new("apb_imp", this);
    evt_imp  = new("evt_imp", this);
  endfunction

  // APB stream: decode register writes and sample pslverr.
  virtual function void write_apb(apb_seq_item t);
    if (!cov_enable) return;
    cg_err.sample(t.slverr);
    if (t.dir == APB_WRITE) begin
      case (t.addr)
        DATA_OUT_OFF: cg_dout.sample(t.wdata);
        DIR_OFF:      cg_dir.sample(t.wdata);
        INT_EN_OFF:   cg_inten.sample(t.wdata);
        default: /* other addresses covered by cg_err / VIP coverage */ ;
      endcase
    end
  endfunction

  // Gpio-event stream from the reference model.
  virtual function void write_evt(apb_gpio_evt_item e);
    if (!cov_enable) return;
    cg_evt.sample(e.edge_detected, e.irq_asserted, e.w1c_race);
  endfunction

endclass

`endif // APB_GPIO_COVERAGE_SVH
