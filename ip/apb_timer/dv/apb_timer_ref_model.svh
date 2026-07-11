// -----------------------------------------------------------------------------
// apb_timer_ref_model.svh : cycle-/tick-accurate predictor for apb_timer.
//
//   The model shadows the DUT's architectural state (ctrl_en/mode/irqen, load,
//   prescale, cnt, psc, status_irq) and steps it ONCE PER posedge using the
//   EXACT next-state equations of rtl/apb_timer.sv (same ordering: register
//   writes, then the prescaler/counter, then one-shot auto-clear, then the
//   sticky RW1C STATUS.IRQ with "HW-set wins").
//
//   It observes the APB bus itself through apb_if.m_mon_cb (the same preponed
//   sampling the apb_monitor uses), so at posedge T:
//     * the shadow `state` at the TOP of the iteration equals the DUT registers
//       that are VISIBLE during the cycle ending at T (i.e. set at posedge T-1).
//     * a READ completing at T returns f(that visible state)  -> predicted rdata
//     * irq visible at T = irqen & status_irq of that same visible state
//       -> exactly what the passive irq monitor samples at posedge T.
//   Because the model predicts irq from the pre-update state (not one cycle
//   ahead) and both it and the irq monitor count posedges from t=0, expected and
//   observed irq edges carry the SAME cycle stamp (the scoreboard pairs them by
//   order and checks edge polarity exactly, cycle within +/-1 for sampling skew).
//
//   Outputs (analysis ports):
//     apb_exp_ap : one expected apb_seq_item per completed APB beat
//     irq_exp_ap : one expected timer_irq_item per predicted irq edge
//     evt_ap     : timer events (timeout / reload type / W1C-race) for coverage
// -----------------------------------------------------------------------------
`ifndef APB_TIMER_REF_MODEL_SVH
`define APB_TIMER_REF_MODEL_SVH

// Lightweight timer-event record published for functional coverage.
class apb_timer_evt_item extends uvm_sequence_item;
  bit timeout;          // a timeout/tick-to-zero fired this cycle
  bit periodic_reload;  // timeout in periodic mode (reload + keep running)
  bit oneshot_expire;   // timeout in one-shot mode (EN auto-clears)
  bit w1c_race;         // STATUS W1C attempted the same cycle HW set (HW wins)
  bit load_is_zero;     // the (re)load value at this timeout was 0

  `uvm_object_utils_begin(apb_timer_evt_item)
    `uvm_field_int(timeout,         UVM_ALL_ON)
    `uvm_field_int(periodic_reload, UVM_ALL_ON)
    `uvm_field_int(oneshot_expire,  UVM_ALL_ON)
    `uvm_field_int(w1c_race,        UVM_ALL_ON)
    `uvm_field_int(load_is_zero,    UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "apb_timer_evt_item");
    super.new(name);
  endfunction
endclass

class apb_timer_ref_model extends uvm_component;
  `uvm_component_utils(apb_timer_ref_model)

  virtual apb_if vif;

  uvm_analysis_port #(apb_seq_item)       apb_exp_ap;
  uvm_analysis_port #(timer_irq_item)     irq_exp_ap;
  uvm_analysis_port #(apb_timer_evt_item) evt_ap;

  // ---- shadow architectural state (matches apb_timer.sv) ----
  bit        ctrl_en, ctrl_mode, ctrl_irqen;
  bit [31:0] load_reg;
  bit [7:0]  prescale_reg;
  bit        status_irq;
  bit [31:0] cnt;
  bit [7:0]  psc;

  bit          prev_irq;
  int unsigned cyc;

  // register byte offsets (spec 2)
  localparam bit [7:0] CTRL_OFF     = 8'h00;
  localparam bit [7:0] LOAD_OFF     = 8'h04;
  localparam bit [7:0] VALUE_OFF    = 8'h08;
  localparam bit [7:0] STATUS_OFF   = 8'h0C;
  localparam bit [7:0] PRESCALE_OFF = 8'h10;

  function new(string name = "apb_timer_ref_model", uvm_component parent = null);
    super.new(name, parent);
    apb_exp_ap = new("apb_exp_ap", this);
    irq_exp_ap = new("irq_exp_ap", this);
    evt_ap     = new("evt_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("REFMODEL_NOVIF", "virtual apb_if 'vif' not set for ref model")
  endfunction

  function void do_reset();
    ctrl_en = 0; ctrl_mode = 0; ctrl_irqen = 0;
    load_reg = '0; prescale_reg = '0; status_irq = 0;
    cnt = '0; psc = '0;
  endfunction

  function bit is_legal(bit [7:0] a);
    return (a inside {CTRL_OFF, LOAD_OFF, VALUE_OFF, STATUS_OFF, PRESCALE_OFF});
  endfunction

  // Predicted read data from the CURRENTLY-VISIBLE register state (reserved=0).
  function bit [31:0] predict_read(bit [7:0] a);
    case (a)
      CTRL_OFF:     predict_read = {29'b0, ctrl_irqen, ctrl_mode, ctrl_en};
      LOAD_OFF:     predict_read = load_reg;
      VALUE_OFF:    predict_read = cnt;
      STATUS_OFF:   predict_read = {31'b0, status_irq};
      PRESCALE_OFF: predict_read = {24'b0, prescale_reg};
      default:      predict_read = 32'h0;
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    do_reset();
    prev_irq = 1'b0;
    cyc      = 0;
    forever begin
      @(vif.m_mon_cb);
      if (vif.rst_n !== 1'b1) begin   // async assert / sync deassert
        do_reset();
        prev_irq = 1'b0;
        cyc++;
        continue;
      end
      step();
      cyc++;
    end
  endtask

  // One posedge step: predict responses for THIS cycle from current state, then
  // advance the shadow state with the DUT's exact equations.
  task step();
    // ---- sample the APB bus (preponed, same as apb_monitor) ----
    bit        s_psel    = vif.m_mon_cb.psel;
    bit        s_penable = vif.m_mon_cb.penable;
    bit        s_pready  = vif.m_mon_cb.pready;
    bit        s_pwrite  = vif.m_mon_cb.pwrite;
    bit [7:0]  s_paddr   = vif.m_mon_cb.paddr;
    bit [31:0] s_pwdata  = vif.m_mon_cb.pwdata;

    bit legal       = is_legal(s_paddr);
    bit beat        = s_psel && s_penable && s_pready;
    bit wr_en       = beat && s_pwrite && legal;
    bit wr_status   = wr_en && (s_paddr == STATUS_OFF);
    bit start_event = wr_en && (s_paddr == CTRL_OFF) && s_pwdata[0] && !ctrl_en;
    bit timeout     = ctrl_en && (psc == prescale_reg) &&
                      ((cnt == 32'h0) || (cnt == 32'h1));

    // ---- 1) predicted irq edge (visible THIS cycle from current state) ----
    bit irq_now = ctrl_irqen & status_irq;
    if (irq_now !== prev_irq) begin
      timer_irq_item it = timer_irq_item::type_id::create("irq_exp");
      it.irq    = irq_now;
      it.rose   = irq_now & ~prev_irq;
      it.fell   = ~irq_now & prev_irq;
      it.cyc    = cyc;
      it.tstamp = $time;
      irq_exp_ap.write(it);
    end
    prev_irq = irq_now;

    // ---- 2) predicted APB response for a beat completing THIS cycle ----
    if (beat) begin
      apb_seq_item ex = apb_seq_item::type_id::create("apb_exp");
      ex.addr   = s_paddr;
      ex.dir    = s_pwrite ? APB_WRITE : APB_READ;
      ex.wdata  = s_pwdata;
      ex.slverr = ~legal;                                       // unmapped -> pslverr
      ex.rdata  = (!s_pwrite && legal) ? predict_read(s_paddr) : 32'h0;
      apb_exp_ap.write(ex);
    end

    // ---- 3) timer events for coverage (before committing next state) ----
    if (timeout) begin
      apb_timer_evt_item ev = apb_timer_evt_item::type_id::create("evt");
      ev.timeout         = 1'b1;
      ev.periodic_reload = ctrl_mode;
      ev.oneshot_expire  = ~ctrl_mode;
      ev.w1c_race        = wr_status && s_pwdata[0];  // W1C same cycle HW sets
      ev.load_is_zero    = (load_reg == 32'h0);
      evt_ap.write(ev);
    end

    // ---- 4) next-state (RTL-identical; all RHS use CURRENT state) ----
    begin
      bit        n_en    = ctrl_en;
      bit        n_mode  = ctrl_mode;
      bit        n_irqen = ctrl_irqen;
      bit [31:0] n_load  = load_reg;
      bit [7:0]  n_pre   = prescale_reg;
      bit        n_sirq  = status_irq;
      bit [31:0] n_cnt   = cnt;
      bit [7:0]  n_psc   = psc;

      // 4a) APB register writes (control/config).
      if (wr_en) begin
        case (s_paddr)
          CTRL_OFF: begin
            n_en    = s_pwdata[0];
            n_mode  = s_pwdata[1];
            n_irqen = s_pwdata[2];
          end
          LOAD_OFF:     n_load = s_pwdata;
          PRESCALE_OFF: n_pre  = s_pwdata[7:0];
          default: /* STATUS -> W1C below; VALUE -> RO dropped */ ;
        endcase
      end

      // 4b) prescaler / down-counter (start_event and counting are exclusive).
      if (start_event) begin
        n_cnt = load_reg;
        n_psc = 8'h0;
      end
      else if (ctrl_en) begin
        if (psc == prescale_reg) begin
          n_psc = 8'h0;
          if (timeout) n_cnt = ctrl_mode ? load_reg : 32'h0;
          else         n_cnt = cnt - 32'h1;
        end
        else begin
          n_psc = psc + 8'h1;
        end
      end

      // 4c) one-shot auto-clear of EN on timeout (wins the CTRL-write race).
      if (timeout && !ctrl_mode) n_en = 1'b0;

      // 4d) STATUS.IRQ sticky RW1C : HW set wins a same-cycle W1C.
      if (timeout)                        n_sirq = 1'b1;
      else if (wr_status && s_pwdata[0])  n_sirq = 1'b0;

      // commit
      ctrl_en      = n_en;
      ctrl_mode    = n_mode;
      ctrl_irqen   = n_irqen;
      load_reg     = n_load;
      prescale_reg = n_pre;
      status_irq   = n_sirq;
      cnt          = n_cnt;
      psc          = n_psc;
    end
  endtask

endclass

`endif // APB_TIMER_REF_MODEL_SVH
