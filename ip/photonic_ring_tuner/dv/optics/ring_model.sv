`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_model : behavioural real-number model of the microring + photodiode + ADC
//              (spec 7.2). NON-SYNTHESIZABLE BY DESIGN -- it is DV code, it lives
//              under dv/, and it never appears in a synthesis filelist.
//
//   Evaluated once per posedge clk (spec 7.2):
//
//     temp  <- temp + (real'(dac_code) - temp) / tau_cycles   // 1st-order lag
//     d      = temp - res_code                                // detuning, codes
//     trans  = 1.0 / (1.0 + (2.0*d / fwhm_code)**2)           // Lorentzian
//     adc_r  = p_peak_lsb * trans + noise                     // photodiode -> ADC
//     adc    = clamp(round(adc_r), 0, 2**ADC_WIDTH - 1)
//
//   * trans is 1.0 at d = 0 and 0.5 at |d| = fwhm_code/2 -- the lineshape a
//     single ring actually produces at its drop port.
//   * laser_on = 0 forces trans to 0 (dark fibre): the ADC then reads noise
//     only, which is what makes the false-lock guard (MINPOW) testable.
//   * noise is uniform in +/- noise_lsb and is drawn with $urandom_range, so
//     every run reproduces exactly from the simulator/UVM seed. $random and
//     unseeded real math are deliberately NOT used.
//   * Everything is in DAC-code space and CLOCK CYCLES (spec 7.1 / 7.3): a
//     faithful thermal tau would be 1e5..1e6 cycles and no acquisition would
//     finish in simulation. Only the RATIO settle_q / tau_cycles is observable
//     to the controller, and that ratio is preserved -- so is every bug.
//
//   Timing: the interface fields are published with NON-BLOCKING assignments so
//   they update in the NBA region, exactly like RTL. The DUT therefore sees the
//   ADC value produced by the PREVIOUS edge (a registered ADC output, which is
//   what a real converter presents) and every clocking-block sampler sees a
//   consistent preponed snapshot.
//
// -----------------------------------------------------------------------------
// BACKENDS (ring_if.model_mode, encoded as ring_cfg::ring_model_e)
// -----------------------------------------------------------------------------
//   RING_MODEL_SV (0)      the SystemVerilog physics above. THE DEFAULT, and the
//                          only backend that exists unless the build is compiled
//                          with +define+RING_DPI.
//   RING_MODEL_DPI (1)     the same physics evaluated by the C model behind
//                          common/dpi (photonics_dpi_pkg). The SV branch is
//                          skipped; the loop is closed through C.
//   RING_MODEL_COMPARE (2) BOTH, in lockstep, on identical inputs, checked
//                          against each other every clock. This is the mode the
//                          equivalence test runs in, and it is how you qualify
//                          somebody else's C model against a reference you trust.
//
//   The whole DPI layer sits behind `ifdef RING_DPI. With the define ABSENT this
//   file has exactly the dependencies it had before the layer existed -- no
//   package import, no C symbol, no UVM -- because the UVM runs for this
//   repository happen on EDA Playground, which cannot compile user C, and that
//   flow must not break. Asking for backend 1 or 2 in such a build is a $fatal
//   NAMING THE MISSING DEFINE; it is never a silent fallback to the SV model,
//   because "the DPI test passed" when no DPI ran is the worst outcome available.
//
//   Backend selection: ring_cfg::model_mode, overridable by +RING_MODEL=sv|dpi|
//   compare, resolved once in ring_cfg (see env_cfg) and pushed onto ring_if by
//   ring_cfg::apply(). This module reads it while reset is still asserted -- the
//   apply() happens in start_of_simulation_phase, i.e. at time 0, before the
//   first posedge, and the tb holds reset for several clocks after that -- and
//   publishes the backend it ACTUALLY ran on ring_if.model_mode_active, which is
//   what functional coverage samples. Coverage of "what the config asked for"
//   would prove nothing.
//
// -----------------------------------------------------------------------------
// THE NOISE DRAW STAYS IN SYSTEMVERILOG
// -----------------------------------------------------------------------------
//   Exactly ONE $urandom_range draw happens per post-reset edge in EVERY
//   backend, from this module, and the resulting sample is PASSED to the C model
//   rather than re-drawn there. Two reasons, and they are not stylistic:
//     * reproducibility -- a C-side rand() is invisible to -sv_seed /
//       +ntb_random_seed, so a failing run could not be replayed from its seed;
//     * COMPARE would otherwise be meaningless -- two models fed different noise
//       disagree for a reason that has nothing to do with either being wrong.
//   Keeping the draw in one place also keeps the RNG stream identical across
//   backends, so an SV run and a DPI run of the same seed see the same physics.
// -----------------------------------------------------------------------------
module ring_model #(
    parameter int DAC_WIDTH = 12,
    parameter int ADC_WIDTH = 12
) (
    ring_if.model_mp ring
);

`ifdef RING_DPI
  // The DPI layer, the UVM report server for the equivalence errors, and
  // nothing else. All three appear ONLY in this build.
  import photonics_dpi_pkg::*;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
`endif

  localparam int AdcMax = (1 << ADC_WIDTH) - 1;

  // Backend encoding -- must match ring_cfg::ring_model_e and the comment in
  // ring_if. Kept as localparam ints so this module needs no package to decode
  // the mode in the default build.
  localparam int ModelSv      = 0;
  localparam int ModelDpi     = 1;
  localparam int ModelCompare = 2;

  // Thermal state, in DAC codes. Local (not the interface copy) so the model
  // owns exactly one driver of it; the interface copy is published each edge.
  real temp;

  // Per-edge temporaries (module scope: one always block owns them, and
  // declarations inside an unnamed begin/end are not portable across tools).
  real tau;
  real fwhm;
  real d;
  real trans;
  real x;
  real adc_r;
  real noise;                 // the single per-edge noise draw (see the header)
  int  adc_sv;                // SV-backend quantized ADC code

  bit  warned_tau;
  bit  warned_fwhm;

  // Backend actually in use, latched while reset is asserted.
  int  mode_q = ModelSv;

  // COMPARE tallies. Local copies because a modport OUTPUT may be written but
  // not read back; the interface copies are published with NBAs, exactly like
  // temp / temp_code.
  int  cmp_count;
  int  mismatch_count;

  // DPI-side results. Declared in BOTH builds so the publish below is one
  // unconditional if/else -- fewer `ifdef seams means fewer ways for the two
  // variants to drift apart. They are only ever WRITTEN under RING_DPI, and the
  // branch that reads them is unreachable without it (resolve_mode() fatals
  // first).
  int  adc_dpi;
  real det_dpi;
  real temp_dpi;

`ifdef RING_DPI
  // One handle per instance: it carries the C model's integrator state, so two
  // ring_model instances must never share one. Created lazily, freed in `final`.
  chandle h_dpi;

  // Equivalence tolerance. Both models are IEEE-754 doubles doing the same
  // operations in the same order, so the QUANTIZED adc_code must match EXACTLY
  // and the pre-quantization reals should be bit-identical. The tolerance below
  // exists only to absorb a host FPU that keeps intermediates in wider
  // registers (x87 excess precision), NOT to paper over a different formula:
  // one extra rounding is ~1e-16 relative, a reordered or re-derived expression
  // is orders of magnitude bigger and still fails.
  localparam real EquivAbsTol = 1.0e-9;
  localparam real EquivRelTol = 1.0e-12;

  // Report the first few mismatches in full and then count: a model that is
  // wrong is usually wrong every clock, and 100k identical UVM_ERRORs bury the
  // FIRST failing cycle, which is the only one worth debugging. The total is
  // published on ring_if so the test can fail on the count.
  localparam int MaxMismatchReports = 16;
  int  n_reported;
`endif

  // Round-to-nearest + clamp into the ADC's unsigned range.
  // The argument is named `adc_in`, NOT `x`: `x` is a module-scope variable
  // (the normalized detuning of the Lorentzian) and a formal of the same name
  // would shadow it inside this function -- legal, and exactly the kind of
  // silent aliasing that makes a model hard to trust.
  function automatic int quantize(real adc_in);
    int q;
    if (adc_in <= 0.0) return 0;
    q = $rtoi(adc_in + 0.5);
    return (q > AdcMax) ? AdcMax : q;
  endfunction

  // Uniform in +/- amp, seeded (reproducible from the UVM seed).
  function automatic real uniform_noise(real amp);
    if (amp <= 0.0) return 0.0;
    return amp * ((real'($urandom_range(0, 20000)) / 10000.0) - 1.0);
  endfunction

  // Validate the requested backend and refuse -- loudly, by name -- to pretend.
  function automatic int resolve_mode();
    int m;
    m = ring.model_mode;
    if ((m != ModelSv) && (m != ModelDpi) && (m != ModelCompare))
      $fatal(1, "ring_model: ring_if.model_mode = %0d is not 0 (sv), 1 (dpi) or 2 (compare)", m);
`ifndef RING_DPI
    if (m != ModelSv)
      $fatal(1, {"ring_model: backend %0d (dpi/compare) was requested but this build has no DPI ",
                 "layer. Recompile with +define+RING_DPI and link common/dpi's shared library, ",
                 "or run with +RING_MODEL=sv. Falling back to the SV model silently would let a ",
                 "'DPI equivalence' run pass having never called C."}, m);
`endif
    return m;
  endfunction

`ifdef RING_DPI
  // Agreement test for the pre-quantization reals (see EquivAbsTol above).
  function automatic bit real_agrees(real a, real b);
    real diff;
    real mag;
    diff = (a > b) ? (a - b) : (b - a);
    mag  = (a < 0.0) ? -a : a;
    return (diff <= (EquivAbsTol + EquivRelTol * mag));
  endfunction

  // One mismatch report: the cycle, every input both models were given, and
  // both sets of outputs. Anything less and the first thing you have to do on a
  // failure is re-run to find out what was fed in.
  function automatic void report_mismatch(int unsigned cyc);
    if (n_reported >= MaxMismatchReports) return;
    n_reported = n_reported + 1;
    `uvm_error("RING_DPI_EQUIV", $sformatf(
      {"SV/DPI model mismatch on compared cycle %0d (mismatch %0d of this run)\n",
       "  inputs : dac_code=%0d noise=%0.17g res_code=%0.17g fwhm=%0.17g tau=%0.17g ",
       "p_peak=%0.17g laser_on=%0b adc_max=%0d\n",
       "  SV     : adc_code=%0d detune=%0.17g temp=%0.17g\n",
       "  DPI    : adc_code=%0d detune=%0.17g temp=%0.17g\n",
       "  delta  : adc=%0d detune=%0.17g temp=%0.17g (tol = %0.3g + %0.3g*|ref|)"},
      cyc, mismatch_count,
      int'(ring.dac_code), noise, ring.res_code, fwhm, tau, ring.p_peak_lsb,
      ring.laser_on, AdcMax,
      adc_sv, d, temp,
      adc_dpi, det_dpi, temp_dpi,
      adc_sv - adc_dpi, d - det_dpi, temp - temp_dpi,
      EquivAbsTol, EquivRelTol))
    if (n_reported == MaxMismatchReports)
      `uvm_info("RING_DPI_EQUIV", $sformatf(
        {"%0d mismatches reported in full; the rest are counted only and are ",
         "published on ring_if.equiv_mismatch_count"},
        MaxMismatchReports), UVM_LOW)
  endfunction
`endif

  always @(posedge ring.clk or negedge ring.rst_n) begin
    if (!ring.rst_n) begin
      // dac_code drives 0 through reset (spec 1), so the heater is cold.
      temp             = 0.0;
      ring.temp_code   <= 0.0;
      ring.detune_code <= -ring.res_code;
      ring.adc_code    <= '0;

      // Re-resolved on EVERY reset edge, on purpose: the x->0 transition of
      // rst_n at time 0 fires this block before the UVM start_of_simulation
      // phase has necessarily run ring_cfg::apply(), and at that point the
      // interface still holds its default (SV). The reset is held for several
      // clocks afterwards, so the last resolution before release is the one the
      // configuration asked for.
      mode_q                 = resolve_mode();
      ring.model_mode_active <= mode_q;

      cmp_count                 = 0;
      mismatch_count            = 0;
      ring.equiv_cmp_count      <= 0;
      ring.equiv_mismatch_count <= 0;

`ifdef RING_DPI
      n_reported = 0;
      temp_dpi   = 0.0;
      det_dpi    = -ring.res_code;
      adc_dpi    = 0;
      if (mode_q != ModelSv) begin
        if (h_dpi == null) h_dpi = ring_dpi_new();
        ring_dpi_reset(h_dpi);
      end
`endif
    end
    else begin
      // Defensive guards: the DV constrains tau_cycles >= 1.0 and fwhm_code >= 1
      // (see ring_cfg), so these only fire if someone drives the interface by
      // hand. tau < 1 would make the discrete lag overshoot; fwhm 0 divides.
      // The CLAMPED values are what both backends are given, so the C model
      // never has to guess a clamping rule that differs from this one.
      tau  = ring.tau_cycles;
      fwhm = ring.fwhm_code;
      if (tau < 1.0) begin
        if (!warned_tau) begin
          warned_tau = 1'b1;
          $warning("ring_model: tau_cycles=%0.3f < 1.0, clamped to 1.0", tau);
        end
        tau = 1.0;
      end
      if (fwhm < 1.0) begin
        if (!warned_fwhm) begin
          warned_fwhm = 1'b1;
          $warning("ring_model: fwhm_code=%0.3f < 1.0, clamped to 1.0", fwhm);
        end
        fwhm = 1.0;
      end

      // ---- THE noise draw : once per edge, in EVERY backend ----------------
      // Unconditional so the RNG stream does not depend on the backend (see the
      // header). uniform_noise() consumes nothing when noise_lsb <= 0, exactly
      // as before, so a no-define build's random stream is bit-for-bit what it
      // has always been.
      noise = uniform_noise(ring.noise_lsb);

      // ---- SV reference model (skipped only in the DPI-only backend) -------
      if (mode_q != ModelDpi) begin
        // 1st-order thermal lag toward the commanded heater code.
        temp   = temp + (real'(ring.dac_code) - temp) / tau;

        // Detuning and Lorentzian transmission (0 with the laser off).
        d      = temp - ring.res_code;
        x      = 2.0 * d / fwhm;
        trans  = ring.laser_on ? (1.0 / (1.0 + x * x)) : 0.0;

        // Photodiode -> ADC, with uniform read noise, rounded and clamped.
        adc_r  = ring.p_peak_lsb * trans + noise;
        adc_sv = quantize(adc_r);
      end

`ifdef RING_DPI
      // ---- C model, on IDENTICAL inputs ------------------------------------
      if (mode_q != ModelSv) begin
        // Configured every step so a mid-test change (the laser going off, the
        // resonance being moved) reaches C on exactly the cycle the SV branch
        // above sees it. The ABI requires config to leave the integrator state
        // alone; if it does not, COMPARE is what tells you.
        ring_dpi_config(h_dpi, ring.res_code, fwhm, tau, ring.p_peak_lsb,
                        ring.noise_lsb, ring.laser_on ? 1 : 0, AdcMax);
        adc_dpi = ring_dpi_step(h_dpi, int'(ring.dac_code), noise,
                                det_dpi, temp_dpi);
        // The C model owns the clamp; check that it honoured it rather than
        // letting an out-of-range value be truncated into the loop, where it
        // would look like a DUT bug.
        if ((adc_dpi < 0) || (adc_dpi > AdcMax)) begin
          `uvm_error("RING_DPI_RANGE", $sformatf(
            {"photonics_ring_step returned adc_code=%0d, outside [0:%0d] - ",
             "the C model did not clamp"},
            adc_dpi, AdcMax))
          adc_dpi = (adc_dpi < 0) ? 0 : AdcMax;
        end
      end

      // ---- the equivalence check -------------------------------------------
      if (mode_q == ModelCompare) begin
        cmp_count = cmp_count + 1;
        if ((adc_sv !== adc_dpi) || !real_agrees(d, det_dpi) ||
            !real_agrees(temp, temp_dpi)) begin
          mismatch_count = mismatch_count + 1;
          report_mismatch(cmp_count);
        end
        ring.equiv_cmp_count      <= cmp_count;
        ring.equiv_mismatch_count <= mismatch_count;
      end
`endif

      // ---- publish ----------------------------------------------------------
      // COMPARE drives the loop from the SV REFERENCE. That is deliberate: if
      // the C model is broken, the failure then shows up as a localized,
      // readable stream of RING_DPI_EQUIV errors instead of as a garbage
      // acquisition whose real cause is three abstraction layers away. The C
      // model is still fully evaluated on every one of those clocks -- it is
      // being measured, not bypassed.
      if (mode_q == ModelDpi) begin
        ring.adc_code    <= ADC_WIDTH'(adc_dpi);
        ring.temp_code   <= temp_dpi;
        ring.detune_code <= det_dpi;
      end
      else begin
        ring.adc_code    <= ADC_WIDTH'(adc_sv);
        ring.temp_code   <= temp;
        ring.detune_code <= d;
      end
    end
  end

`ifdef RING_DPI
  // Give the handle back, so a leak checker over the C model stays quiet and a
  // long regression does not accumulate one ring per run.
  final begin
    if (h_dpi != null) begin
      ring_dpi_free(h_dpi);
      h_dpi = null;
    end
  end
`endif

endmodule
