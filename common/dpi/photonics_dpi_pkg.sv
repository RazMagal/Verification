// -----------------------------------------------------------------------------
// photonics_dpi_pkg.sv : the SystemVerilog half of the photonics DPI-C ABI.
//
//   *** THIS FILE IS INERT UNLESS `RING_DPI` IS DEFINED. ***
//
//   Without +define+RING_DPI the package below is EMPTY -- it declares NO
//   import "DPI-C" / export "DPI-C" and no functions at all, so the elaborated
//   image has no reference to any C symbol and no shared library to
//   link. That is not a nicety: the UVM runs for this repository happen on EDA
//   Playground, which does not let you compile your own C, and the existing
//   flow must keep working there byte-for-byte. Default flow = no define = pure
//   SystemVerilog.
//
//   ---------------------------------------------------------------------------
//   THE ABI (frozen -- the C side is written against exactly these prototypes)
//   ---------------------------------------------------------------------------
//     chandle photonics_ring_new();
//     void    photonics_ring_free  (chandle h);
//     void    photonics_ring_config(chandle h, real res_code, real fwhm_code,
//                                   real tau_cycles, real p_peak_lsb,
//                                   real noise_lsb, int laser_on, int adc_max);
//     void    photonics_ring_reset (chandle h);
//     int     photonics_ring_step  (chandle h, int dac_code, real noise_sample,
//                                   output real detune_code, output real temp_code);
//     string  photonics_dpi_version();
//     export  sv_ring_event(int ev, real value);   // 0 = resonance crossing,
//                                                  // 1 = ADC clipped at max
//
//   ---------------------------------------------------------------------------
//   WHY photonics_ring_step MUST BE DECLARED `context`  (the classic DPI gotcha)
//   ---------------------------------------------------------------------------
//   photonics_ring_step calls BACK into SystemVerilog through the exported
//   sv_ring_event. An exported task/function is not a free-floating C symbol:
//   it belongs to a SystemVerilog SCOPE (this package), and the simulator has to
//   know WHICH scope to run it in. That scope is the "DPI context", and it is
//   only established for imports declared `context`.
//
//   A plain (non-context) import is allowed to be called with no SystemVerilog
//   context at all; the simulator is then free to omit the bookkeeping, and the
//   callback fails at run time -- typically an "svGetScope: no context" / "DPI
//   call outside of a context" abort, or, worse on some tools, a silent no-op or
//   a call into whatever scope happened to be current. That failure appears only
//   at run time, only when the C model actually decides to raise an event, and
//   it looks nothing like its cause. Hence: `context`.
//
//   Second half of the same gotcha: the context an imported context function
//   gets is the scope it is CALLED FROM. If ring_model (a module) called
//   photonics_ring_step directly, the context would be the ring_model instance,
//   where sv_ring_event does not exist. Every call therefore goes through the
//   thin ring_dpi_* wrappers BELOW, so the call site is lexically inside this
//   package -- the same scope that owns the export. Do not call the raw imports
//   from outside this package.
//
//   ---------------------------------------------------------------------------
//   RANDOMNESS: SystemVerilog OWNS IT
//   ---------------------------------------------------------------------------
//   `noise_sample` is the FULLY SCALED additive ADC noise, in ADC LSBs, already
//   drawn in SystemVerilog with $urandom_range from the simulation seed. The C
//   model must add it VERBATIM (adc_r = p_peak_lsb*trans + noise_sample) and
//   must never call rand()/random()/drand48() itself: reproducing a failing run
//   from its seed is worth more than any convenience, and a C-side RNG is
//   invisible to +ntb_random_seed / -sv_seed.
//   `noise_lsb` is still passed to photonics_ring_config, and the ABI gives it
//   exactly TWO permitted uses: bookkeeping (so the C model can report the band
//   it was configured for) and a pure ON/OFF GATE -- `noise_lsb <= 0.0` means
//   "no read noise", so the sample is discarded, which mirrors the SV model's
//   uniform_noise() returning 0.0 for amp <= 0. That gate is what the C model
//   implements today, and it is a no-op in practice precisely because the SV
//   caller already passes 0.0 in that case; it is documented anyway, because an
//   ABI note that disagrees with the code is worse than no note. What
//   `noise_lsb` MUST NOT do is RE-SCALE noise_sample (e.g. noise_lsb *
//   noise_sample): the sample arrives fully scaled, and re-scaling it would
//   both square the amplitude and make the C model's noise a function of a
//   value SystemVerilog already applied.
//
//   Two more contract notes that the equivalence test will catch if broken:
//     * tau_cycles and fwhm_code arrive ALREADY CLAMPED to >= 1.0 by the SV
//       caller, so C never has to defend against a zero divide and never has to
//       guess a clamping rule that differs from the reference model's.
//     * photonics_ring_config is called every step and MUST be free of side
//       effects on the integrator state (only photonics_ring_reset clears it).
//       Calling it per step is what lets a mid-test change -- the laser being
//       switched off, say -- reach C on exactly the cycle the SV reference sees
//       it, with no "did I remember to re-configure?" hazard.
//
//   ---------------------------------------------------------------------------
//   HANDLE OWNERSHIP
//   ---------------------------------------------------------------------------
//   One chandle per ring_model instance, created lazily on first use and freed
//   in that module's `final` block. The handle carries the per-instance
//   integrator state, so two ring_model instances must never share one.
//   The event counters below are, by contrast, PACKAGE-STATIC (shared by every
//   instance); with a single ring in this environment that is exactly what is
//   wanted, and it is stated here rather than discovered later.
// -----------------------------------------------------------------------------
`ifndef PHOTONICS_DPI_PKG_SV
`define PHOTONICS_DPI_PKG_SV

package photonics_dpi_pkg;

  // NOTE: without `RING_DPI this package is deliberately EMPTY -- not "empty
  // except for a helper". It used to carry a ring_dpi_available() predicate for
  // guarded code to interrogate, but nothing could legitimately call it: the
  // places that must refuse a DPI backend (ring_cfg::resolve_model_mode and
  // ring_model::resolve_mode) are compiled WITHOUT the define in the default
  // flow, so calling into this package there would give the default flow a
  // dependency on it -- exactly the dependency the guard exists to prevent, and
  // one that would break the EDA Playground flow, where this file is not pasted
  // at all. Inside `ifdef RING_DPI the predicate could only ever return 1, i.e.
  // it was dead either way. Those two sites keep their own `ifdef and name the
  // missing define in the message.

`ifdef RING_DPI

  // ---- event codes carried by sv_ring_event (frozen ABI) -------------------
  localparam int RingEvResonance = 0;   // the ring crossed its resonance
  localparam int RingEvAdcClip  = 1;   // the photodiode reading clipped at max
  localparam int RingEvN         = 2;

  // ---- imports : EXACTLY the frozen prototypes -----------------------------
  import "DPI-C" function chandle photonics_ring_new();
  import "DPI-C" function void    photonics_ring_free(input chandle h);
  import "DPI-C" function void    photonics_ring_config(input chandle h,
      input real res_code, input real fwhm_code, input real tau_cycles,
      input real p_peak_lsb, input real noise_lsb,
      input int laser_on, input int adc_max);
  import "DPI-C" function void    photonics_ring_reset(input chandle h);

  // `context` is MANDATORY here -- see the header. This import calls back into
  // SystemVerilog through the export below, and only a context import carries
  // the SystemVerilog scope the simulator needs to resolve that callback.
  import "DPI-C" context function int photonics_ring_step(input chandle h,
      input int dac_code, input real noise_sample,
      output real detune_code, output real temp_code);

  import "DPI-C" function string  photonics_dpi_version();

  // ---- export : the callback the C model raises events through -------------
  export "DPI-C" function sv_ring_event;

  // ---- observable state the DV can check -----------------------------------
  // Counted rather than merely printed, so a test can assert that the callback
  // path is ALIVE. A `context` that was quietly dropped shows up here as a run
  // that raised zero events on stimulus that provably produces some.
  int  ev_count [RingEvN];
  real ev_last  [RingEvN];
  int  ev_unknown;            // events with an out-of-range code (C-side bug)
  bit  ev_trace = 1'b0;       // set by a test to $display every callback

  // The exported callback itself. Deliberately UVM-free: this package is the
  // ABI layer and is reusable by a non-UVM bench, and a callback that can be
  // hit every clock has no business dragging the report server in.
  function automatic void sv_ring_event(input int ev, input real value);
    if ((ev < 0) || (ev >= RingEvN)) begin
      ev_unknown = ev_unknown + 1;
      $display("[%0t] photonics_dpi_pkg: sv_ring_event got unknown event code %0d (value %0f)",
               $time, ev, value);
      return;
    end
    ev_count[ev] = ev_count[ev] + 1;
    ev_last[ev]  = value;
    if (ev_trace)
      $display("[%0t] photonics_dpi_pkg: sv_ring_event ev=%0d value=%0f (count %0d)",
               $time, ev, value, ev_count[ev]);
  endfunction

  function automatic int ring_dpi_event_count(input int ev);
    if ((ev < 0) || (ev >= RingEvN)) return 0;
    return ev_count[ev];
  endfunction

  function automatic int ring_dpi_event_total();
    int t = 0;
    for (int i = 0; i < RingEvN; i++) t += ev_count[i];
    return t;
  endfunction

  function automatic real ring_dpi_event_last(input int ev);
    if ((ev < 0) || (ev >= RingEvN)) return 0.0;
    return ev_last[ev];
  endfunction

  function automatic void ring_dpi_clear_events();
    for (int i = 0; i < RingEvN; i++) begin
      ev_count[i] = 0;
      ev_last[i]  = 0.0;
    end
    ev_unknown = 0;
  endfunction

  function automatic string ring_dpi_event_str();
    return $sformatf("resonance=%0d clip=%0d unknown=%0d",
                     ev_count[RingEvResonance], ev_count[RingEvAdcClip],
                     ev_unknown);
  endfunction

  // ---- wrappers ------------------------------------------------------------
  // Every DPI call in the environment goes through one of these, for two
  // reasons: (a) ring_dpi_step's call site must sit in THIS scope so the
  // exported sv_ring_event resolves (see the header), and (b) a null handle
  // becomes a readable $fatal here instead of an undefined C dereference.
  function automatic chandle ring_dpi_new();
    chandle h;
    h = photonics_ring_new();
    if (h == null)
      $fatal(1, {"photonics_dpi_pkg: photonics_ring_new() returned null - ",
                 "the C model could not allocate a ring"});
    return h;
  endfunction

  function automatic void ring_dpi_free(input chandle h);
    if (h == null) return;
    photonics_ring_free(h);
  endfunction

  function automatic void ring_dpi_config(input chandle h,
      input real res_code, input real fwhm_code, input real tau_cycles,
      input real p_peak_lsb, input real noise_lsb,
      input int laser_on, input int adc_max);
    if (h == null)
      $fatal(1, "photonics_dpi_pkg: ring_dpi_config on a null handle");
    photonics_ring_config(h, res_code, fwhm_code, tau_cycles, p_peak_lsb,
                          noise_lsb, laser_on, adc_max);
  endfunction

  function automatic void ring_dpi_reset(input chandle h);
    if (h == null)
      $fatal(1, "photonics_dpi_pkg: ring_dpi_reset on a null handle");
    photonics_ring_reset(h);
  endfunction

  // THE call that needs the context. Keep it here.
  function automatic int ring_dpi_step(input chandle h, input int dac_code,
                                       input real noise_sample,
                                       output real detune_code,
                                       output real temp_code);
    if (h == null)
      $fatal(1, "photonics_dpi_pkg: ring_dpi_step on a null handle");
    return photonics_ring_step(h, dac_code, noise_sample, detune_code, temp_code);
  endfunction

  function automatic string ring_dpi_version();
    return photonics_dpi_version();
  endfunction

`endif  // RING_DPI

endpackage : photonics_dpi_pkg

`endif  // PHOTONICS_DPI_PKG_SV
