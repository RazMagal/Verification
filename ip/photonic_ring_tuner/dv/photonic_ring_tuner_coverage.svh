// -----------------------------------------------------------------------------
// photonic_ring_tuner_coverage.svh : tuner-specific functional coverage (the VIP
//   already covers generic APB dir/addr/slverr). Two analysis inputs:
//     _apb : observed APB transactions (decode the register programming + pslverr)
//     _acq : one acquisition-result record per run, from the scoreboard
//
//   Coverage plan (spec 7.6):
//     * settle_q / tau_cycles RATIO, binned {<1, 1-2, 2-4, >4}, CROSSED WITH THE
//       LOCK OUTCOME. This cross is the headline result of the whole project: it
//       shows the loop failing to acquire when it samples the photodiode before
//       the ring has thermally settled, which is the archetypal photonic control
//       bug. The cross is left COMPLETE on purpose - the (<1, locked) cell is
//       exactly the cell whose appearance would be a finding, so it must not be
//       hidden behind an ignore_bins.
//     * initial detuning sign, and res_code low / mid / high in the DAC range
//       (plus "beyond the range", the rail case)
//     * fwhm_code narrow / medium / wide (a high-Q ring is harder to find)
//     * dither_eff relative to fwhm_code (too large a dither cannot resolve the
//       peak)
//     * outcome bins: locked / sweep-error / rail-error / lost-lock / none.
//       `lost_lock` is filled by photonic_ring_tuner_lock_loss_test, which
//       acquires a lock and then breaks it deliberately; without that directed
//       test the bin is unfillable (nothing else disturbs an established lock,
//       and in lock_test a lost lock is a uvm_error).
//     * register programming: CTRL.EN, STEP.DITHER, STEP.SWEEP (including the
//       clamp-to-1 zero case), SETTLE, LOCK_CFG.THRESH / MINPOW, pslverr
//     * WHICH OPTICAL MODEL BACKEND ran (SV / DPI-C / lockstep COMPARE), taken
//       from ring_model's own report rather than from the config, so a
//       regression can demonstrate the DPI path was exercised instead of
//       silently skipped. The two DPI bins are ignore_bins'd in a build without
//       +define+RING_DPI, where they are structurally unreachable.
//
//   NOTE: coverpoint expressions must be integral, so the `real` physics is
//   mapped to bin INDICES by the helper functions below rather than sampled
//   directly. Keeping the mapping in one place also keeps the bin edges
//   readable next to the coverage plan.
//
//   HONESTY OF THE CROSSES. Both crosses below contain cells that NO test in
//   this suite can reach, because the stimulus that produces one axis pins the
//   other. Leaving them in makes the reported percentage a lie by omission --
//   the denominator would count cells no amount of seeds can ever fill. They
//   are therefore excluded with `ignore_bins`, each with the reason it is
//   unreachable stated next to it, so the remaining number means what it says.
//   Cells that are merely UNLIKELY are NOT excluded, and in particular the
//   (ratio < 1, locked) cell is kept: its appearance would be a finding.
// -----------------------------------------------------------------------------
`ifndef PHOTONIC_RING_TUNER_COVERAGE_SVH
`define PHOTONIC_RING_TUNER_COVERAGE_SVH

`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_acq)

class photonic_ring_tuner_coverage extends uvm_component;
  `uvm_component_utils(photonic_ring_tuner_coverage)

  uvm_analysis_imp_apb #(apb_seq_item, photonic_ring_tuner_coverage) apb_imp;
  uvm_analysis_imp_acq #(photonic_ring_tuner_acq_item,
                         photonic_ring_tuner_coverage)               acq_imp;

  bit cov_enable = 1'b1;

  // Offsets are spec-2 register-map facts; their WIDTH is the bus's, so it comes
  // from photonic_ring_tuner_params.svh (which takes it from the VIP).
  localparam bit [TUNER_ADDR_WIDTH-1:0] CTRL_OFF     = 'h00;
  localparam bit [TUNER_ADDR_WIDTH-1:0] STEP_OFF     = 'h04;
  localparam bit [TUNER_ADDR_WIDTH-1:0] SETTLE_OFF   = 'h08;
  localparam bit [TUNER_ADDR_WIDTH-1:0] LOCK_CFG_OFF = 'h0C;

  // Bin edges on the PHYSICAL axes are fractions of full scale written at the
  // 12-bit scale and rescaled, exactly as ring_cfg's regime bounds are: on the
  // default build DAC_FS == REF_FS == 4096, so `(k * DAC_FS) / REF_FS == k` and
  // every edge below is numerically what it always was.
  localparam int DAC_FS = TUNER_DAC_FS;
  localparam int REF_FS = TUNER_REF_FS;

  // cp_minpow's edges are the one REGISTER axis that is not a register-map fact:
  // like cg_settle's and cp_thresh's, they are placed around the field's RESET
  // value so that `nom` means "programmed at the default", and MINPOW's reset is
  // ADC full-scale/16 (photonic_ring_tuner_params.svh) rather than a constant.
  // Deriving them keeps `nom` meaning that on a re-parameterized build instead
  // of quietly becoming an empty bin; at the default ADC_WIDTH = 12 they are
  // 255 / 256 / 1023 / 1024, i.e. exactly the edges they have always been.
  // Both clamps below only bite on builds the RTL refuses to elaborate anyway
  // (ADC_WIDTH < 5 clamps the reset to 1; ADC_WIDTH >= 18 pushes 4x the reset
  // past the 16-bit field), and they cost at most a one-value bin overlap there,
  // which is legal and is the honest description of such a build.
  localparam int MINPOW_NOM_LO = TUNER_MINPOW_RST;
  localparam int MINPOW_NOM_HI = (4 * TUNER_MINPOW_RST - 1 > 65535)
                                 ? 65535 : (4 * TUNER_MINPOW_RST - 1);
  localparam int MINPOW_LOW_HI = (MINPOW_NOM_LO > 1) ? (MINPOW_NOM_LO - 1) : 1;
  localparam int MINPOW_HIGH_LO = (MINPOW_NOM_HI >= 65535) ? 65535 : (MINPOW_NOM_HI + 1);

  // ---- register programming ------------------------------------------------
  covergroup cg_ctrl with function sample(bit en);
    option.per_instance = 1;
    option.name         = "cg_ctrl";
    cp_en : coverpoint en { bins dis = {1'b0}; bins ena = {1'b1}; }
  endgroup

  covergroup cg_step with function sample(bit [7:0] dither, bit [7:0] sweep);
    option.per_instance = 1;
    option.name         = "cg_step";
    // 0 is legal and must be clamped to 1 by hardware (spec 2).
    cp_dither : coverpoint dither {
      bins zero = {0};
      bins tiny = {[1:3]};
      bins nom  = {[4:15]};
      bins big  = {[16:63]};
      bins huge = {[64:255]};
    }
    cp_sweep : coverpoint sweep {
      bins zero = {0};
      bins tiny = {[1:7]};
      bins nom  = {[8:63]};
      bins big  = {[64:255]};
    }
    // STEP's two fields are only ever driven off their nominal band ONE AT A
    // TIME, so most of this 5 x 4 cross is structurally dead:
    //   * ratio_vseq sweeps DITHER across 1..64 with SWEEP fixed at 0x20 (nom);
    //   * smoke_vseq programs two directed pairs, (0x02,0x05) and (0x10,0x08);
    //   * uvm_reg_bit_bash_seq walks ONE bit at a time from the 0x2004 reset, so
    //     whenever SWEEP leaves 0x20 (-> 0x00, 0x60, 0xA0) DITHER is still 0x04.
    // Declaring the resulting empty cells "missing coverage" would overstate
    // what this suite can ever reach, so they are ignored with the reason.
    x_step : cross cp_dither, cp_sweep {
      // SWEEP = 0 arrives only from bit-bashing bit 5 of the 0x20 reset value,
      // which leaves DITHER at its own reset value of 0x04 (the `nom` bin).
      ignore_bins sweep_zero_only_with_nom_dither =
          binsof(cp_sweep.zero) && binsof(cp_dither) intersect {0, [1:3], [16:255]};
      // SWEEP >= 64 likewise arrives only from bit-bashing bit 6 or 7 (0x60 /
      // 0xA0), again with DITHER still at 0x04.
      ignore_bins sweep_big_only_with_nom_dither =
          binsof(cp_sweep.big)  && binsof(cp_dither) intersect {0, [1:3], [16:255]};
      // A SWEEP of 1..7 exists only as smoke_vseq's directed (0x02, 0x05) pair,
      // i.e. always alongside a `tiny` DITHER. Bit-bash cannot produce it (no
      // single-bit flip of 0x20 lands in 1..7) and no other vseq programs it.
      ignore_bins sweep_tiny_only_with_tiny_dither =
          binsof(cp_sweep.tiny) && binsof(cp_dither) intersect {0, [4:255]};
    }
  endgroup

  covergroup cg_settle with function sample(bit [15:0] settle);
    option.per_instance = 1;
    option.name         = "cg_settle";
    cp_settle : coverpoint settle {
      bins zero  = {0};
      bins short = {[1:7]};
      bins mid   = {[8:31]};
      bins nom   = {[32:127]};
      bins long  = {[128:65535]};
    }
  endgroup

  covergroup cg_lock_cfg with function sample(bit [15:0] thresh, bit [15:0] minpow);
    option.per_instance = 1;
    option.name         = "cg_lock_cfg";
    cp_thresh : coverpoint thresh {
      bins zero = {0};
      bins tight= {[1:7]};
      bins nom  = {[8:63]};
      bins loose= {[64:65535]};
    }
    // MINPOW == 0 disables the false-lock guard entirely (spec 3.4). The other
    // three edges are relative to the RESET MINPOW (= ADC full-scale/16); see
    // the localparams above. 0 / 1..255 / 256..1023 / 1024.. at ADC_WIDTH = 12.
    cp_minpow : coverpoint minpow {
      bins zero = {0};
      bins low  = {[1 : MINPOW_LOW_HI]};
      bins nom  = {[MINPOW_NOM_LO : MINPOW_NOM_HI]};
      bins high = {[MINPOW_HIGH_LO : 65535]};
    }
  endgroup

  covergroup cg_err with function sample(bit e);
    option.per_instance = 1;
    option.name         = "cg_err";
    cp_slverr : coverpoint e { bins ok = {1'b0}; bins err = {1'b1}; }
  endgroup

  // ---- the acquisition result : the headline cross -------------------------
  covergroup cg_acq with function sample(int ratio_b, int outcome_b, int res_b,
                                         int fwhm_b, int dith_b, bit det_pos,
                                         bit laser, int backend_b);
    option.per_instance = 1;
    option.name         = "cg_acq";

    // WHICH MODEL PRODUCED THIS RESULT. Sampled from ring_model's own report
    // (ring_if.model_mode_active), not from the config, so a regression can
    // PROVE the DPI path ran rather than assume it: a build where the C library
    // failed to link, or a run where +RING_MODEL never reached the model, shows
    // up here as an empty dpi/compare bin instead of as a quiet green pass.
    cp_backend : coverpoint backend_b {
      // -1 = the scoreboard never sampled ring_if out of reset, so NO backend
      // was observed. It is illegal rather than folded into `sv`, because a run
      // that observed nothing is not evidence for the SV path -- counting it
      // there would report coverage the run never earned. illegal_bins also
      // keeps it out of the denominator, so it cannot become a permanent hole.
      illegal_bins never_sampled = {-1};
      bins sv      = {0};   // RING_MODEL_SV      : pure SystemVerilog
      bins dpi     = {1};   // RING_MODEL_DPI     : the C model closes the loop
      bins compare = {2};   // RING_MODEL_COMPARE : both, checked every clock
`ifndef RING_DPI
      // Structurally unreachable in this build: without +define+RING_DPI there
      // is no C model, and ring_cfg::resolve_model_mode() turns a request for
      // either backend into a uvm_fatal. Leaving them in the denominator would
      // report a permanent coverage hole that no amount of seeds can close --
      // the same lie-by-omission the x_ratio_outcome ignore_bins avoid.
      ignore_bins no_dpi_layer_in_this_build = {1, 2};
`endif
    }
    cp_ratio : coverpoint ratio_b {
      bins lt1  = {0};   // sampled BEFORE the ring settled -> must not acquire
      bins r1_2 = {1};
      bins r2_4 = {2};
      bins gt4  = {3};   // properly settled
    }
    cp_outcome : coverpoint outcome_b {
      bins locked    = {0};
      bins sweep_err = {1};
      bins rail_err  = {2};
      bins lost_lock = {3};
      bins none      = {4};
    }
    // THE headline cross (spec 7.6). Kept as complete as the stimulus can make
    // it -- in particular EVERY (ratio, locked) cell stays in, because the
    // (lt1, locked) cell is exactly the one whose appearance would be a finding
    // and must never be hidden. Only cells whose OUTCOME can be produced by a
    // single regime that pins SETTLE and tau are excluded:
    //   * sweep_err comes only from the DARK regime, run at the default
    //     SETTLE = 32 against tau <= 8 cycles => ratio >= 4 always;
    //   * lost_lock comes only from lock_loss_test, run at the default
    //     SETTLE = 32 on a LOCKABLE ring (tau <= 8) => ratio >= 4 always.
    // rail_err and `none` keep all four ratio cells: rail_w1c_race_test runs the
    // rail regime at SETTLE = 4 (ratio 0.5..4) and ratio_test sweeps the ratio
    // deliberately, so those cells are reachable.
    x_ratio_outcome : cross cp_ratio, cp_outcome {
      ignore_bins sweep_err_only_at_default_settle =
          binsof(cp_outcome.sweep_err) && binsof(cp_ratio) intersect {0, 1, 2};
      ignore_bins lost_lock_only_at_default_settle =
          binsof(cp_outcome.lost_lock) && binsof(cp_ratio) intersect {0, 1, 2};
    }

    cp_res : coverpoint res_b {
      bins low        = {0};
      bins mid        = {1};
      bins high       = {2};
      bins out_of_rng = {3};
    }
    // `medium` is a reserved word in Verilog (trireg charge strength), so the
    // middle bin is spelled `med`.
    cp_fwhm : coverpoint fwhm_b {
      bins narrow = {0};
      bins med    = {1};
      bins wide   = {2};
    }
    cp_dither_fwhm : coverpoint dith_b {
      bins fine       = {0};   // dither << linewidth : resolves the peak
      bins coarse     = {1};
      bins too_coarse = {2};   // dither ~ linewidth : cannot resolve the peak
    }
    cp_detune_sign : coverpoint det_pos {
      bins below = {1'b0};     // ring colder than resonance (cold start)
      bins above = {1'b1};     // ring hotter than resonance (re-acquire)
    }
    cp_laser : coverpoint laser { bins off = {1'b0}; bins on = {1'b1}; }
  endgroup

  function new(string name = "photonic_ring_tuner_coverage",
               uvm_component parent = null);
    super.new(name, parent);
    cg_ctrl     = new();
    cg_step     = new();
    cg_settle   = new();
    cg_lock_cfg = new();
    cg_err      = new();
    cg_acq      = new();
    apb_imp     = new("apb_imp", this);
    acq_imp     = new("acq_imp", this);
  endfunction

  // ---- real -> bin-index mapping (coverpoints must be integral) ------------
  function int ratio_bin(real r);
    if (r <  1.0) return 0;
    if (r <  2.0) return 1;
    if (r <  4.0) return 2;
    return 3;
  endfunction

  // low / mid / high thirds of the tuning range, plus "beyond the top code".
  function int res_bin(real res);
    if (res > real'(TUNER_DAC_MAX))            return 3;   // outside the range
    if (res < real'((1365 * DAC_FS) / REF_FS)) return 0;
    if (res < real'((2731 * DAC_FS) / REF_FS)) return 1;
    return 2;
  endfunction

  function int fwhm_bin(real fwhm);
    if (fwhm < real'((256 * DAC_FS) / REF_FS)) return 0;
    if (fwhm < real'((640 * DAC_FS) / REF_FS)) return 1;
    return 2;
  endfunction

  // dither_eff / fwhm_code : how well the dither can resolve the lineshape.
  function int dither_bin(int unsigned dither_eff, real fwhm);
    real q = real'(dither_eff) / ((fwhm < 1.0) ? 1.0 : fwhm);
    if (q < 0.02) return 0;
    if (q < 0.10) return 1;
    return 2;
  endfunction

  function int outcome_bin(photonic_ring_tuner_acq_item e);
    if (e.locked_seen && e.lost_lock) return 3;   // acquired then lost
    if (e.locked_seen)                return 0;
    if (e.rail_err)                   return 2;
    if (e.sweep_err)                  return 1;
    return 4;                                     // nothing resolved
  endfunction

  // APB stream: decode the register programming and sample pslverr.
  virtual function void write_apb(apb_seq_item t);
    if (!cov_enable) return;
    cg_err.sample(t.slverr);
    if ((t.dir == APB_WRITE) && !t.slverr) begin
      case (t.addr)
        CTRL_OFF:     cg_ctrl.sample(t.wdata[0]);
        STEP_OFF:     cg_step.sample(t.wdata[7:0], t.wdata[15:8]);
        SETTLE_OFF:   cg_settle.sample(t.wdata[15:0]);
        LOCK_CFG_OFF: cg_lock_cfg.sample(t.wdata[15:0], t.wdata[31:16]);
        default: /* other addresses covered by cg_err / VIP coverage */ ;
      endcase
    end
  endfunction

  // Acquisition-result stream from the scoreboard.
  virtual function void write_acq(photonic_ring_tuner_acq_item e);
    if (!cov_enable) return;
    cg_acq.sample(ratio_bin(e.ratio), outcome_bin(e), res_bin(e.res_code),
                  fwhm_bin(e.fwhm_code), dither_bin(e.dither_eff, e.fwhm_code),
                  e.init_detune_pos, e.laser_on, e.model_backend);
    `uvm_info("COV_ACQ", $sformatf(
      "ratio=%0.3f (bin %0d) outcome=%0d locked=%0b sweep_err=%0b rail_err=%0b acq_cycles=%0d backend=%0d",
      e.ratio, ratio_bin(e.ratio), outcome_bin(e), e.locked_seen, e.sweep_err,
      e.rail_err, e.acq_cycles, e.model_backend), UVM_LOW)
  endfunction

endclass

`endif // PHOTONIC_RING_TUNER_COVERAGE_SVH
