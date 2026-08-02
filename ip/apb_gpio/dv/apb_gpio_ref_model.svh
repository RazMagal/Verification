// -----------------------------------------------------------------------------
// apb_gpio_ref_model.svh : cycle-exact predictor for apb_gpio.
//
//   The model shadows the DUT's architectural state (dout_q/dir_q/inten_q/
//   intstat_q and the input-synchronizer flops) and steps it ONCE PER posedge
//   using the DUT's exact next-state equations, observing BOTH the APB bus
//   (apb_if.m_mon_cb) and the external pins (gpio_if.mon_cb) through the same
//   preponed sampling the monitors use. Discipline is identical to the timer
//   reference model: at the top of the iteration for posedge n the shadow equals
//   the DUT registers VISIBLE during the cycle ending at n; a beat completing at
//   n reads f(that visible state), and gpio_out/gpio_oe/irq sampled at n equal
//   the predicted values of that same visible state.
//
//   --- 2-FF input-synchronizer latency (the key modelling detail) ------------
//   gpio_in is passed through two flops to din_sync (spec 3.2). The DUT detects a
//   rising edge COMBINATIONALLY from the two synchronizer stages (rtl):
//        din_meta <= gpio_in ;  din_sync <= din_meta ;   // 2-FF synchronizer
//        din_rise  = din_meta & ~din_sync ;              // stage-1 high, stage-2 still low
//        intstat_q <= (intstat_q & ~w1c_clear) | din_rise ;
//   i.e. intstat sets on the SAME edge din_sync reaches 1 (no extra history flop).
//   Writing X@k for "value during the cycle after posedge k":
//        din_meta@n = gpio_in@(n-1)              (1st sync flop)
//        din_sync@n = din_meta@(n-1) = gpio_in@(n-2)   (2nd flop == DATA_IN)
//        din_rise@n = din_meta@n & ~din_sync@n
//        intstat_q@n = (intstat_q@(n-1) & ~w1c@(n-1)) | din_rise@(n-1)
//   The shadow carries g_meta (din_meta) and g_sync (din_sync == DATA_IN). Each
//   step samples gpio_in (the value the 1st flop captures), predicts reads/
//   outputs from the CURRENT (pre-advance) shadow, computes the edge from the
//   CURRENT two stages (rise = g_meta & ~g_sync == din_rise of the previous
//   cycle), then advances g_sync <= g_meta ; g_meta <= gpio_in_sampled. So
//   DATA_IN readback == g_sync and INT_STATUS follows the DUT bit-for-bit,
//   cycle-for-cycle. There is NO internal loopback: gpio_in is the only input.
//
//   Clear-then-set ordering matches the RTL exactly: (intstat & ~clr) | rise, so
//   a same-cycle W1C-vs-rising-edge race on a bit leaves it SET (HW-set-wins).
//
//   Outputs (analysis ports):
//     apb_exp_ap : one expected apb_seq_item per completed APB beat
//     pin_exp_ap : one expected gpio_mon_item whenever gpio_out/gpio_oe/irq change
//     evt_ap     : gpio events (edge / irq-assert / W1C-race) for coverage
// -----------------------------------------------------------------------------
`ifndef APB_GPIO_REF_MODEL_SVH
`define APB_GPIO_REF_MODEL_SVH

// Lightweight gpio-event record published for functional coverage.
class apb_gpio_evt_item extends uvm_sequence_item;
  bit edge_detected;   // a rising edge on din_sync fired this cycle (any pin)
  bit irq_asserted;    // irq rose (0 -> 1) this cycle
  bit w1c_race;        // W1C attempted on a bit HW set the same cycle (HW wins)

  `uvm_object_utils_begin(apb_gpio_evt_item)
    `uvm_field_int(edge_detected, UVM_ALL_ON)
    `uvm_field_int(irq_asserted,  UVM_ALL_ON)
    `uvm_field_int(w1c_race,      UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "apb_gpio_evt_item");
    super.new(name);
  endfunction
endclass

class apb_gpio_ref_model extends uvm_component;
  `uvm_component_utils(apb_gpio_ref_model)

  virtual apb_if  vif;       // APB bus (key "vif")
  virtual gpio_if pin_vif;   // external pins (key "pin_vif")

  uvm_analysis_port #(apb_seq_item)      apb_exp_ap;
  uvm_analysis_port #(gpio_mon_item)     pin_exp_ap;
  uvm_analysis_port #(apb_gpio_evt_item) evt_ap;

  // ---- shadow architectural state (matches apb_gpio.sv) ----
  // One bit per pin, exactly like the DUT registers (APB_GPIO_NUM_PINS IS the
  // IP's DATA_WIDTH - see apb_gpio_params.svh).
  bit [APB_GPIO_NUM_PINS-1:0] dout_q;      // DATA_OUT register
  bit [APB_GPIO_NUM_PINS-1:0] dir_q;       // DIR register
  bit [APB_GPIO_NUM_PINS-1:0] inten_q;     // INT_EN register
  bit [APB_GPIO_NUM_PINS-1:0] intstat_q;   // INT_STATUS register (sticky)
  bit [APB_GPIO_NUM_PINS-1:0] g_meta;      // 1st sync flop  (din_meta)
  bit [APB_GPIO_NUM_PINS-1:0] g_sync;      // 2nd sync flop  (din_sync == DATA_IN)

  // baselines for change-detection on the predicted outputs
  bit [APB_GPIO_NUM_PINS-1:0] prev_out;
  bit [APB_GPIO_NUM_PINS-1:0] prev_oe;
  bit        prev_irq;

  int unsigned cyc;

  // register byte offsets (spec 2)
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] DATA_OUT_OFF   = 'h00;
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] DATA_IN_OFF    = 'h04;
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] DIR_OFF        = 'h08;
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] INT_STATUS_OFF = 'h0C;
  localparam bit [APB_GPIO_ADDR_WIDTH-1:0] INT_EN_OFF     = 'h10;

  function new(string name = "apb_gpio_ref_model", uvm_component parent = null);
    super.new(name, parent);
    apb_exp_ap = new("apb_exp_ap", this);
    pin_exp_ap = new("pin_exp_ap", this);
    evt_ap     = new("evt_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
      `uvm_fatal("REFMODEL_NOVIF", "virtual apb_if 'vif' not set for ref model")
    if (!uvm_config_db#(virtual gpio_if)::get(this, "", "pin_vif", pin_vif))
      `uvm_fatal("REFMODEL_NOPINVIF",
                 "virtual gpio_if 'pin_vif' not set for ref model")
  endfunction

  function void do_reset();
    dout_q = '0; dir_q = '0; inten_q = '0; intstat_q = '0;
    g_meta = '0; g_sync = '0;
  endfunction

  function bit is_legal(bit [APB_GPIO_ADDR_WIDTH-1:0] a);
    return (a inside {DATA_OUT_OFF, DATA_IN_OFF, DIR_OFF,
                      INT_STATUS_OFF, INT_EN_OFF});
  endfunction

  // Predicted read data from the CURRENTLY-VISIBLE register state.
  function bit [APB_GPIO_DATA_WIDTH-1:0] predict_read(bit [APB_GPIO_ADDR_WIDTH-1:0] a);
    case (a)
      DATA_OUT_OFF:   predict_read = dout_q;
      DATA_IN_OFF:    predict_read = g_sync;      // synchronized live sample
      DIR_OFF:        predict_read = dir_q;
      INT_STATUS_OFF: predict_read = intstat_q;
      INT_EN_OFF:     predict_read = inten_q;
      default:        predict_read = '0;
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    do_reset();
    prev_out = '0; prev_oe = '0; prev_irq = 1'b0;
    cyc      = 0;
    forever begin
      @(vif.m_mon_cb);
      if (vif.rst_n !== 1'b1) begin   // async assert / sync deassert
        do_reset();
        prev_out = '0; prev_oe = '0; prev_irq = 1'b0;
        cyc++;
        continue;
      end
      step();
      cyc++;
    end
  endtask

  // One posedge step: predict responses/outputs for THIS cycle from current
  // state, then advance the shadow with the DUT's exact equations.
  task step();
    // ---- sample the APB bus (preponed, same as apb_monitor) ----
    bit        s_psel    = vif.m_mon_cb.psel;
    bit        s_penable = vif.m_mon_cb.penable;
    bit        s_pready  = vif.m_mon_cb.pready;
    bit        s_pwrite  = vif.m_mon_cb.pwrite;
    bit [APB_GPIO_ADDR_WIDTH-1:0] s_paddr  = vif.m_mon_cb.paddr;
    bit [APB_GPIO_DATA_WIDTH-1:0] s_pwdata = vif.m_mon_cb.pwdata;
    // ---- sample the external pins (preponed, same as gpio_monitor) ----
    bit [APB_GPIO_NUM_PINS-1:0]   s_gpio_in = pin_vif.mon_cb.gpio_in;

    bit legal      = is_legal(s_paddr);
    bit beat       = s_psel && s_penable && s_pready;
    bit wr_en      = beat && s_pwrite && legal;
    bit wr_dout    = wr_en && (s_paddr == DATA_OUT_OFF);
    bit wr_dir     = wr_en && (s_paddr == DIR_OFF);
    bit wr_inten   = wr_en && (s_paddr == INT_EN_OFF);
    bit wr_intstat = wr_en && (s_paddr == INT_STATUS_OFF);

    // rising edge = stage-1 high, stage-2 still low (RTL: din_meta & ~din_sync),
    // taken from the CURRENT shadow == din_rise of the previous cycle.
    bit [APB_GPIO_NUM_PINS-1:0] rise = g_meta & ~g_sync;
    // per-pin SW clear request on a completing INT_STATUS write.
    bit [APB_GPIO_NUM_PINS-1:0] clr  = wr_intstat ? s_pwdata : '0;

    // ---- predicted outputs visible THIS cycle from current shadow ----
    bit [APB_GPIO_NUM_PINS-1:0] out_now = dout_q;
    bit [APB_GPIO_NUM_PINS-1:0] oe_now  = dir_q;
    bit        irq_now  = |(intstat_q & inten_q);
    bit        irq_rose = irq_now & ~prev_irq;

    // ---- 1) predicted pin-output change ----
    if ((out_now !== prev_out) || (oe_now !== prev_oe) || (irq_now !== prev_irq)) begin
      gpio_mon_item pit = gpio_mon_item::type_id::create("pin_exp");
      pit.gpio_out = out_now;
      pit.gpio_oe  = oe_now;
      pit.irq      = irq_now;
      pit.gpio_in  = s_gpio_in;
      pit.cyc      = cyc;
      pit.tstamp   = $time;
      pin_exp_ap.write(pit);
    end
    prev_out = out_now;
    prev_oe  = oe_now;
    prev_irq = irq_now;

    // ---- 2) predicted APB response for a beat completing THIS cycle ----
    if (beat) begin
      apb_seq_item ex = apb_seq_item::type_id::create("apb_exp");
      ex.addr   = s_paddr;
      ex.dir    = s_pwrite ? APB_WRITE : APB_READ;
      ex.wdata  = s_pwdata;
      ex.slverr = ~legal;                                     // unmapped -> pslverr
      ex.rdata  = (!s_pwrite && legal) ? predict_read(s_paddr) : '0;
      apb_exp_ap.write(ex);
    end

    // ---- 3) gpio events for coverage ----
    begin
      bit w1c_race = wr_intstat && (|(rise & s_pwdata));
      if ((|rise) || irq_rose || w1c_race) begin
        apb_gpio_evt_item ev = apb_gpio_evt_item::type_id::create("evt");
        ev.edge_detected = (|rise);
        ev.irq_asserted  = irq_rose;
        ev.w1c_race      = w1c_race;
        evt_ap.write(ev);
      end
    end

    // ---- 4) next-state (RTL-identical; all RHS use CURRENT state) ----
    begin
      bit [APB_GPIO_NUM_PINS-1:0] n_dout   = dout_q;
      bit [APB_GPIO_NUM_PINS-1:0] n_dir    = dir_q;
      bit [APB_GPIO_NUM_PINS-1:0] n_inten  = inten_q;
      bit [APB_GPIO_NUM_PINS-1:0] n_intstat;
      bit [APB_GPIO_NUM_PINS-1:0] n_meta;
      bit [APB_GPIO_NUM_PINS-1:0] n_sync;

      // 4a) APB register writes (DATA_IN is RO -> dropped; INT_STATUS -> W1C below)
      if (wr_dout)  n_dout  = s_pwdata;
      if (wr_dir)   n_dir   = s_pwdata;
      if (wr_inten) n_inten = s_pwdata;

      // 4b) input synchronizer advance (2 FF -> din_sync)
      n_meta = s_gpio_in;
      n_sync = g_meta;

      // 4c) INT_STATUS sticky RW1C : clear first, then HW rising-edge set ORs in
      //     so a same-cycle edge-vs-W1C leaves the bit SET (HW-set-wins). This is
      //     bit-identical to the RTL: (intstat_q & ~intstat_clr) | din_rise.
      n_intstat = (intstat_q & ~clr) | rise;

      // commit
      dout_q    = n_dout;
      dir_q     = n_dir;
      inten_q   = n_inten;
      intstat_q = n_intstat;
      g_meta    = n_meta;
      g_sync    = n_sync;
    end
  endtask

endclass

`endif // APB_GPIO_REF_MODEL_SVH
