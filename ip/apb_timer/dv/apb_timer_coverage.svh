// -----------------------------------------------------------------------------
// apb_timer_coverage.svh : timer-specific functional coverage (the VIP already
//   covers generic APB dir/addr/slverr). Two analysis inputs:
//     _apb : observed APB transactions (decode register writes + pslverr)
//     _evt : reference-model timer events (timeout / reload type / W1C race)
//
//   Coverage plan hit here:
//     CTRL.EN, CTRL.MODE, CTRL.IRQ_EN and MODE x IRQ_EN cross
//     PRESCALE bins {0, 1..15, 16..254, 255}
//     LOAD     bins {0, 1, 2..15, large}
//     pslverr seen
//     timeout occurred; one-shot expire vs periodic reload; LOAD==0 timeout;
//     W1C-while-HW-set race observed
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_COVERAGE_SVH
`define APB_TIMER_COVERAGE_SVH

`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_evt)

class apb_timer_coverage extends uvm_component;
  `uvm_component_utils(apb_timer_coverage)

  uvm_analysis_imp_apb #(apb_seq_item,       apb_timer_coverage) apb_imp;
  uvm_analysis_imp_evt #(apb_timer_evt_item, apb_timer_coverage) evt_imp;

  bit cov_enable = 1'b1;

  localparam bit [7:0] CTRL_OFF     = 8'h00;
  localparam bit [7:0] LOAD_OFF     = 8'h04;
  localparam bit [7:0] STATUS_OFF   = 8'h0C;
  localparam bit [7:0] PRESCALE_OFF = 8'h10;

  // ---- CTRL configuration coverage ----
  covergroup cg_ctrl with function sample(bit en, bit mode, bit irqen);
    option.per_instance = 1;
    option.name         = "cg_ctrl";
    cp_en    : coverpoint en    { bins dis = {1'b0}; bins ena = {1'b1}; }
    cp_mode  : coverpoint mode  { bins oneshot = {1'b0}; bins periodic = {1'b1}; }
    cp_irqen : coverpoint irqen { bins off = {1'b0}; bins on = {1'b1}; }
    x_mode_irqen : cross cp_mode, cp_irqen;
  endgroup

  // ---- PRESCALE value coverage ----
  covergroup cg_prescale with function sample(bit [7:0] p);
    option.per_instance = 1;
    option.name         = "cg_prescale";
    cp_prescale : coverpoint p {
      bins zero  = {0};
      bins lo    = {[1:15]};
      bins mid   = {[16:254]};
      bins max   = {255};
    }
  endgroup

  // ---- LOAD value coverage ----
  covergroup cg_load with function sample(bit [31:0] l);
    option.per_instance = 1;
    option.name         = "cg_load";
    cp_load : coverpoint l {
      bins zero  = {0};
      bins one   = {1};
      bins lo    = {[2:15]};
      bins hi    = {[16:$]};
    }
  endgroup

  // ---- pslverr coverage ----
  covergroup cg_err with function sample(bit e);
    option.per_instance = 1;
    option.name         = "cg_err";
    cp_slverr : coverpoint e { bins ok = {1'b0}; bins err = {1'b1}; }
  endgroup

  // ---- timer-event coverage ----
  covergroup cg_evt with function sample(bit timeout, bit periodic,
                                         bit oneshot, bit w1c_race, bit load0);
    option.per_instance = 1;
    option.name         = "cg_evt";
    cp_timeout  : coverpoint timeout  { bins hit = {1'b1}; }
    cp_periodic : coverpoint periodic { bins hit = {1'b1}; }
    cp_oneshot  : coverpoint oneshot  { bins hit = {1'b1}; }
    cp_w1c_race : coverpoint w1c_race { bins hit = {1'b1}; }
    cp_load0    : coverpoint load0    { bins hit = {1'b1}; }
  endgroup

  function new(string name = "apb_timer_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_ctrl     = new();
    cg_prescale = new();
    cg_load     = new();
    cg_err      = new();
    cg_evt      = new();
    apb_imp = new("apb_imp", this);
    evt_imp = new("evt_imp", this);
  endfunction

  // APB stream: decode register writes and sample pslverr.
  virtual function void write_apb(apb_seq_item t);
    if (!cov_enable) return;
    cg_err.sample(t.slverr);
    if (t.dir == APB_WRITE) begin
      case (t.addr)
        CTRL_OFF:     cg_ctrl.sample(t.wdata[0], t.wdata[1], t.wdata[2]);
        PRESCALE_OFF: cg_prescale.sample(t.wdata[7:0]);
        LOAD_OFF:     cg_load.sample(t.wdata);
        default: /* other addresses covered by cg_err / VIP coverage */ ;
      endcase
    end
  endfunction

  // Timer-event stream from the reference model.
  virtual function void write_evt(apb_timer_evt_item e);
    if (!cov_enable) return;
    cg_evt.sample(e.timeout, e.periodic_reload, e.oneshot_expire,
                  e.w1c_race, e.load_is_zero);
  endfunction

endclass

`endif // APB_TIMER_COVERAGE_SVH
