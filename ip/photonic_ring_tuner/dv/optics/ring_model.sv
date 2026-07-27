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
// -----------------------------------------------------------------------------
module ring_model #(
    parameter int DAC_WIDTH = 12,
    parameter int ADC_WIDTH = 12
) (
    ring_if.model_mp ring
);

  localparam int AdcMax = (1 << ADC_WIDTH) - 1;

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

  bit  warned_tau;
  bit  warned_fwhm;

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

  always @(posedge ring.clk or negedge ring.rst_n) begin
    if (!ring.rst_n) begin
      // dac_code drives 0 through reset (spec 1), so the heater is cold.
      temp             = 0.0;
      ring.temp_code   <= 0.0;
      ring.detune_code <= -ring.res_code;
      ring.adc_code    <= '0;
    end
    else begin
      // Defensive guards: the DV constrains tau_cycles >= 1.0 and fwhm_code >= 1
      // (see ring_cfg), so these only fire if someone drives the interface by
      // hand. tau < 1 would make the discrete lag overshoot; fwhm 0 divides.
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

      // 1st-order thermal lag toward the commanded heater code.
      temp  = temp + (real'(ring.dac_code) - temp) / tau;

      // Detuning and Lorentzian transmission (0 with the laser off).
      d     = temp - ring.res_code;
      x     = 2.0 * d / fwhm;
      trans = ring.laser_on ? (1.0 / (1.0 + x * x)) : 0.0;

      // Photodiode -> ADC, with uniform read noise, rounded and clamped.
      adc_r = ring.p_peak_lsb * trans + uniform_noise(ring.noise_lsb);

      ring.adc_code    <= ADC_WIDTH'(quantize(adc_r));
      ring.temp_code   <= temp;
      ring.detune_code <= d;
    end
  end

endmodule
