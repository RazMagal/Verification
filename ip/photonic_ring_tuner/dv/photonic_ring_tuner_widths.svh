// -----------------------------------------------------------------------------
// photonic_ring_tuner_widths.svh : the photonic_ring_tuner DV's compile-time
//   geometry, as MACROS ONLY.
//
//   Same split as the VIP (common/apb_vip/apb_width_defines.svh +
//   apb_params.svh) and as apb_gpio: macros here, `parameter int` declarations
//   in photonic_ring_tuner_params.svh. The macro half exists because
//   dv/optics/ring_if.sv compiles at $unit, BEFORE photonic_ring_tuner_pkg, so
//   it cannot see a package parameter -- and its DAC_WIDTH / ADC_WIDTH defaults
//   must still be the same numbers as the package's, because a `virtual ring_if`
//   handle is unparameterized and takes those defaults.
//
//   MACROS ONLY, no declarations, so this file is safe to `include anywhere:
//   including it at $unit and again inside the package cannot collide.
//
//   Every macro is `ifndef-guarded, so a command-line +define always wins:
//       +define+TUNER_DAC_W=10 +define+TUNER_ADC_W=10
//   moves the DUT parameter, ring_if, ring_model, the RAL field widths, the
//   scoreboard's DAC_MAX, ring_cfg's regime bounds and the coverage bin edges
//   together, because all of them read these numbers and nothing else.
//
//   LOCK_N rides along here rather than in a file of its own: it is a depth
//   rather than a width, but it is the same kind of knob (a DUT parameter the DV
//   must agree with -- the acquisition deadline counts LOCK_N at-peak
//   iterations), and one file to override is worth more than a tidy name.
//
//   NOT here, deliberately:
//     * the APB address width -- it is the BUS's, see TUNER_ADDR_WIDTH;
//     * the APB data width    -- spec 2's packed-field layout pins it at 32,
//                                so it is a named constant, not a knob.
//   Both are argued at their declaration in photonic_ring_tuner_params.svh.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_WIDTHS_SVH
`define PHOTONIC_RING_TUNER_WIDTHS_SVH

`ifndef TUNER_DAC_W
  `define TUNER_DAC_W 12
`endif
`ifndef TUNER_ADC_W
  `define TUNER_ADC_W 12
`endif
// Spelled without the second underscore so it can never be read as the
// parameter TUNER_LOCK_N it feeds.
`ifndef TUNER_LOCKN
  `define TUNER_LOCKN 4
`endif

// The full scale the DV's PHYSICAL constants are written at: ring_cfg's regime
// bounds, the coverage bin edges and ring_if's fallback ring are fractions of
// full scale spelled as 12-bit codes, and every one of them is rescaled by
// (this build's FS) / TUNER_REF_FS. It is deliberately NOT `ifndef-guarded:
// unlike the widths above it is not a knob but a historical reference, and it
// must NEVER track DAC_WIDTH -- if it did, the ratio would always be 1 and the
// constants would stop scaling, which is the bug this whole file exists to
// prevent. Both photonic_ring_tuner_params.svh and ring_if.sv read it from
// here so the number 4096 is also written down only once.
`define TUNER_REF_FS_CODES 4096

`endif // PHOTONIC_RING_TUNER_WIDTHS_SVH
