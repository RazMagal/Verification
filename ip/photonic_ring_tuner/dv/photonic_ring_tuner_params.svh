// -----------------------------------------------------------------------------
// photonic_ring_tuner_params.svh : the ONE statement of this environment's
//   compile-time geometry. Included FIRST in photonic_ring_tuner_pkg (right
//   after the apb_vip_pkg import it derives the bus widths from) and therefore
//   before anything that uses the values.
//
//   SAME IDIOM AS common/apb_vip/apb_params.svh, for the same reason: a
//   SystemVerilog PACKAGE parameter cannot be overridden per instance, so the
//   knob arrives as a guarded `define that a build overrides at COMPILE TIME
//   (+define+TUNER_DAC_W=10) and the package parameter is elaborated from it.
//   The macro half lives in photonic_ring_tuner_widths.svh, macros only, so the
//   same defaults can also be `include'd at $unit by dv/optics/ring_if.sv --
//   which is why the number 12 appears in exactly one file in this IP.
//
//   EVERYTHING ELSE IS DERIVED FROM THIS FILE AND MUST NOT RESTATE IT:
//     * the RAL field widths AND their reserved padding (reg_block)
//     * the LOCK_CFG reset -- MINPOW is a FRACTION OF ADC FULL SCALE, so it is
//       derived here (TUNER_MINPOW_RST) and restated by nobody: the RAL reset,
//       the scoreboard's shadow and every vseq expectation read it from here
//     * the scoreboard's DAC_MAX and its PD/DAC field slices
//     * ring_cfg's regime bounds and the acquisition-deadline formula (env_cfg)
//     * the coverage bin edges (coverage)
//     * the tb's DUT / apb_if / ring_if / ring_model / SVA-bind parameterization
//
//   dv/optics/ring_if.sv `include's the SAME macro file rather than repeating
//   the defaults: it compiles at $unit, before this package exists, and a
//   package's declarations are not visible there, but a macro-only include is.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_PARAMS_SVH
`define PHOTONIC_RING_TUNER_PARAMS_SVH

  // ---- the DUT parameterization this environment is built for --------------
  // Guarded `define defaults (overridable with +define+TUNER_DAC_W=10 etc).
  // They match photonic_ring_tuner.sv / the spec 1 module header, and the tb
  // parameterizes the DUT from the parameters below, so the RAL and the DUT
  // cannot drift apart.
  `include "photonic_ring_tuner_widths.svh"

  parameter int TUNER_DAC_WIDTH = `TUNER_DAC_W;   // heater DAC resolution
  parameter int TUNER_ADC_WIDTH = `TUNER_ADC_W;   // photodiode ADC resolution
  parameter int TUNER_LOCK_N    = `TUNER_LOCKN;   // at-peak iterations to lock

  // ---- APB geometry : DERIVED, not restated --------------------------------
  // ADDR is NOT a second knob, and deliberately not even a guarded macro of its
  // own the way apb_gpio's is. apb_gpio can legitimately be given a narrower
  // LOCAL decode than the fabric; this IP cannot -- photonic_ring_tuner.sv
  // $fatals unless BUS_ADDR_W == ADDR_WIDTH -- and the VIP's `virtual apb_if`
  // handle is unparameterized, so one build has exactly ONE APB address width:
  // the VIP's. Aliasing the parameter directly means there is no macro that
  // could be overridden into disagreeing with the bus, and
  // +define+APB_ADDR_W=<n> moves the bus, the seq_item, the RAL adapter and
  // this IP together.
  parameter int TUNER_ADDR_WIDTH = APB_ADDR_WIDTH;

  // DATA is a NAMED CONSTANT, deliberately NOT a `define knob, and this file
  // does not pretend otherwise. Spec 2 packs LOCK_CFG.MINPOW into [31:16] and
  // STEP.SWEEP into [15:8], so the register layout this RAL models exists only
  // at 32 bits, and the RTL already $fatals on anything else ("DATA_WIDTH must
  // be 32 (spec 2 field layout)"). Naming it buys readable derivations -- the
  // reserved padding in the RAL is DATA_WIDTH - DAC_WIDTH rather than "20" --
  // without inviting a build that cannot work.
  parameter int TUNER_DATA_WIDTH = 32;

  // ---- derived geometry ----------------------------------------------------
  parameter int TUNER_DAC_MAX = (1 << TUNER_DAC_WIDTH) - 1;   // 4095 @ 12 bits
  parameter int TUNER_ADC_MAX = (1 << TUNER_ADC_WIDTH) - 1;   // 4095 @ 12 bits
  parameter int TUNER_DAC_FS  = TUNER_DAC_MAX + 1;            // 4096 codes
  parameter int TUNER_ADC_FS  = TUNER_ADC_MAX + 1;            // 4096 LSBs

  // ---- spec §2 LOCK_CFG reset : one of the halves scales, one does not ------
  // THE ASYMMETRY IS DELIBERATE, and it is the same asymmetry the RTL's
  // THRESH_RST / MINPOW_RST carry (this file cannot include the RTL, so both
  // derive the SAME formula from the SAME ADC_WIDTH -- and the tb hands the DUT
  // TUNER_ADC_WIDTH, so they cannot drift):
  //
  //   MINPOW is the minimum photodiode reading that qualifies a sweep peak and
  //   gates lock declaration (spec §3.3, §3.4). It is physically A FRACTION OF
  //   THE EXPECTED PEAK -- narrowing the ADC changes the quantization, not the
  //   optics -- so its reset is full-scale/16 = 2**(ADC_WIDTH-4). At the default
  //   ADC_WIDTH = 12 that is exactly 256 = 0x0100, which is what the register
  //   map's "reset 0x0100_0008" always meant.
  //
  //   THRESH does NOT scale. It discriminates a real gradient from the
  //   QUANTIZATION NOISE FLOOR, which is ~0.5 LSB whatever the width, so it is
  //   an absolute LSB count (8/4096 is not a meaningful fraction of anything).
  //
  // Clamps: floored at 1 (2**(ADC_WIDTH-4) rounds to 0 below ADC_WIDTH = 5, and
  // MINPOW = 0 is no false-lock guard at all) and capped at the 16-bit field.
  // The cap is unreachable in any build that elaborates: photonic_ring_tuner.sv
  // $fatals on ADC_WIDTH > 19, because no meaningful fraction of full scale fits
  // the field there. It exists so this expression is TOTAL -- a package cannot
  // $fatal at elaboration, and a RAL reset outside its own field is a worse
  // failure than a clamped one.
  parameter int TUNER_MINPOW_RST = (TUNER_ADC_WIDTH <  5) ? 1
                                 : (TUNER_ADC_WIDTH > 19) ? 16'hFFFF
                                 : (1 << (TUNER_ADC_WIDTH - 4));   // 256 @ 12 bits
  parameter int TUNER_THRESH_RST = 16'h0008;                       // absolute, see above

  // The whole-word LOCK_CFG reset the vseqs check and the spec §2 table shows:
  // 0x0100_0008 at the default ADC_WIDTH = 12.
  parameter int unsigned TUNER_LOCK_CFG_RST =
      (TUNER_MINPOW_RST << 16) | TUNER_THRESH_RST;

  // ---- the scale the DV's PHYSICAL constants are written at ----------------
  // ring_cfg's regime bounds (resonance positions, linewidths, peak powers) and
  // the coverage bin edges are FRACTIONS OF FULL SCALE that happen to be
  // written as 12-bit codes: a 512-code linewidth on a 12-bit DAC is the same
  // physical ring as a 128-code linewidth on a 10-bit one. Each is therefore
  // written as `k * TUNER_DAC_FS / TUNER_REF_FS` (or the ADC equivalent), which
  // is EXACTLY k on the default build -- the rescaling is the identity there,
  // so the numbers a reader sees are the numbers the solver sees -- and tracks
  // the converter on any other build.
  //
  // LIMIT, stated rather than assumed: that rescaling and every DAC/ADC code in
  // this environment are carried in 32-bit `int` (ring_cfg's knobs are `rand
  // int` because SV cannot randomize a `real`, and the deadline arithmetic is
  // int too), so the products above overflow past DAC_WIDTH/ADC_WIDTH = 18.
  // That is a DV limit, not an RTL one; a wider converter needs these bounds
  // carried in `longint`.
  parameter int TUNER_REF_FS = `TUNER_REF_FS_CODES;   // 2**12; ring_if too

`endif // PHOTONIC_RING_TUNER_PARAMS_SVH
