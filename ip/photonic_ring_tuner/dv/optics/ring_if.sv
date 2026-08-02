`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ring_if : optical-side interface for the photonic_ring_tuner IP (spec 7.4).
//
//   This is the interface the DV environment closes the control loop through.
//   It carries three groups of signals:
//
//     1) DUT-FACING (the closed loop)
//          dac_code : DUT output, heater drive  -> ring_model input
//          adc_code : ring_model output         -> DUT input (photodiode/ADC)
//          locked   : DUT output, observed by the scoreboard
//        The loop is CLOSED: the DUT's input is a function of its own output
//        through ring_model, so there is no pre-computable stimulus stream --
//        the stimulus IS the physics below.
//
//     2) CONFIGURATION (spec 7.4, `real`) -- driven by the DV (ring_cfg::apply)
//        before reset is released, and optionally changed mid-test (e.g. the
//        laser being switched off). Never driven by the model.
//
//     3) OBSERVABLES (spec 7.4, `real`) -- driven by the model each posedge.
//        detune_code is the whole point of the exercise: it lets the scoreboard
//        check "the loop locked to the ACTUAL resonance", which is unobservable
//        from the DUT pins alone.
//
//   Sampling discipline: ring_model publishes adc_code / temp_code /
//   detune_code with NON-BLOCKING assignments, so they land in the NBA region
//   exactly like RTL. mon_cb therefore gives the scoreboard a preponed,
//   race-free, cycle-consistent view of BOTH the digital signals and the reals
//   (the reals are in the clocking block deliberately: reading them directly
//   after @(mon_cb) would return the post-edge value and skew them one cycle
//   against dac_code/locked).
//
//   Like gpio_if, a `virtual ring_if` handle is UNPARAMETERIZED and takes these
//   defaults, so every ring_if instance in one build must share these widths --
//   and the defaults are NOT written here. They come from `TUNER_DAC_W /
//   `TUNER_ADC_W, the same macros photonic_ring_tuner_params.svh elaborates the
//   package parameters from. This file compiles at $unit, before any package,
//   so it has to take the widths as macros; that macro-only include is exactly
//   why the two can never disagree.
// -----------------------------------------------------------------------------
`include "photonic_ring_tuner_widths.svh"

interface ring_if #(parameter int DAC_WIDTH = `TUNER_DAC_W,
                    parameter int ADC_WIDTH = `TUNER_ADC_W)
                   (input logic clk, input logic rst_n);

  // ---- 1) DUT-facing -------------------------------------------------------
  logic [DAC_WIDTH-1:0] dac_code;   // DUT -> model (heater DAC drive)
  logic [ADC_WIDTH-1:0] adc_code;   // model -> DUT (free-running ADC reading)
  logic                 locked;     // DUT -> DV (level: loop is locked)

  // ---- 2) Physical configuration (spec 7.4) --------------------------------
  // Initialised to a benign, lockable ring so a testbench that forgets to apply
  // a ring_cfg still simulates something sane instead of dividing by zero.
  // These are FRACTIONS OF FULL SCALE, so they follow the parameters above
  // rather than assuming a 12-bit build: at 12 bits DacFs == AdcFs == RefFs ==
  // 4096 and the values are exactly the 2048 / 512 / 3000 they always were.
  localparam int DacFs = 1 << DAC_WIDTH;          // full scale, DAC codes
  localparam int AdcFs = 1 << ADC_WIDTH;          // full scale, ADC LSBs
  localparam int RefFs = `TUNER_REF_FS_CODES;     // the 12-bit scale k is at

  real res_code   = real'(DacFs / 2);              // aligns the ring: mid-range
  real fwhm_code  = real'(DacFs / 8);              // resonance linewidth, codes
  real tau_cycles = 4.0;      // thermal time constant, CLOCK CYCLES (see 7.3):
                              // a time, not a code, so it takes no width
  real p_peak_lsb = real'((3000 * AdcFs) / RefFs); // ADC reading when aligned
  real noise_lsb  = 0.0;      // uniform ADC noise amplitude, absolute LSBs
  bit  laser_on   = 1'b1;     // 0 => trans forced to 0 (dark fibre)

  // ---- 3) Observables (spec 7.4, driven by ring_model) ---------------------
  real detune_code = 0.0;    // live d = temp - res_code, DAC codes
  real temp_code   = 0.0;    // live thermal state, DAC codes

  // Passive, preponed sampling for the scoreboard / coverage.
  clocking mon_cb @(posedge clk);
    input rst_n;
    input dac_code, adc_code, locked;
    input detune_code, temp_code;
    input res_code, fwhm_code, tau_cycles, p_peak_lsb, noise_lsb, laser_on;
  endclocking

  // The optical model's view: reads the DAC + the physics, drives the ADC + the
  // observables.
  modport model_mp (input  clk, rst_n, dac_code,
                    input  res_code, fwhm_code, tau_cycles, p_peak_lsb,
                           noise_lsb, laser_on,
                    output adc_code, detune_code, temp_code);

  // The DV's view.
  modport mon_mp (clocking mon_cb, input rst_n,
                  input dac_code, adc_code, locked);

endinterface
