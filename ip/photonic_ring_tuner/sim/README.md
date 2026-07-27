# photonic_ring_tuner — UVM verification environment

Full UVM env for the `photonic_ring_tuner` IP: RAL (multi-field and per-field
mixed-access registers), a **real-number optical model** that closes the control
loop, a property-based scoreboard, functional coverage built around the
settle/tau × lock-outcome cross, a virtual-sequence layer, bound SVA, and a
per-vseq test library. Standard UVM-1.2 / IEEE 1800.2. Mirrors the `apb_gpio`
env structure and reuses `common/apb_vip` unchanged.

## What is here

```
ip/photonic_ring_tuner/
  rtl/photonic_ring_tuner.sv          DUT (owned by the RTL agent; do not modify here)
  rtl/photonic_ring_tuner_sva.sv      tuner SVA (bound onto the DUT)
  dv/optics/ring_if.sv                optical interface: DUT-facing loop +
                                      physical config + detune/temp observables
  dv/optics/ring_model.sv             real-number ring + photodiode + ADC model
                                      (spec §7.2, NON-SYNTHESIZABLE by design)
  dv/photonic_ring_tuner_reg_block.svh  RAL: CTRL/STEP/SETTLE/LOCK_CFG/STATUS/DAC/PD
  dv/photonic_ring_tuner_env_cfg.svh    env config + randomizable ring_cfg
  dv/photonic_ring_tuner_scoreboard.svh the five spec-§7.5 checks
  dv/photonic_ring_tuner_coverage.svh   functional coverage (spec §7.6)
  dv/photonic_ring_tuner_env.svh        env (APB agent + RAL predictor + scb + cov)
  dv/seq/photonic_ring_tuner_vseq_lib.svh  virtual sequences
  dv/test/photonic_ring_tuner_test_lib.svh tests (one per vseq)
  dv/photonic_ring_tuner_pkg.sv         DV package (includes all dv .svh)
  tb/photonic_ring_tuner_tb_top.sv      tb top (clk/rst, ifs, DUT, MODEL, binds)
  sim/run.f  sim/Makefile  sim/README.md
common/apb_vip/                       reused APB VIP (do not modify)
```

## The closed loop (what makes this env different)

The DUT's `adc_code` input is a function of its own `dac_code` output, through
`ring_model`:

```
dut.dac_code --> ring_if --> ring_model (thermal lag, Lorentzian, ADC) --> ring_if.adc_code --> dut
```

So there is **no stimulus sequence to write**. The interesting stimulus is the
*physics*: `ring_cfg` randomizes where the resonance sits, how sharp it is, how
slow the heater is, how bright the laser is; the vseqs then program the loop over
the RAL and **wait for a physical outcome**.

Everything the model does is seeded (`$urandom_range` for the ADC noise, integer
knobs randomized through `randomize()`), so a run reproduces exactly from
`-sv_seed` / `+ntb_random_seed`. `real` cannot be `rand` in SystemVerilog, so
`ring_cfg` randomizes integer knobs and derives the reals in `post_randomize()`.

## Time scaling (spec §7.3 — read this before judging `tau_cycles`)

A real microring's thermal time constant is microseconds to milliseconds; at
100 MHz a faithful `tau` would be 10^5–10^6 clocks and one lock acquisition
would never finish in simulation. `tau_cycles` is therefore **scaled down to
tens of cycles**.

That is sound because the controller cannot observe `tau` in absolute time — it
only ever observes the **ratio `settle_q / tau_cycles`**, i.e. whether it waited
long enough for the ring to reach its new temperature before sampling the
photodiode. Preserving the ratio preserves every bug the loop can have, which is
why the coverage plan bins the **ratio** (and crosses it with the lock outcome)
rather than binning `tau`.

## Compile order (see `run.f`)

Interfaces compile at `$unit` **before** the packages that use their virtual-
interface types:

1. `common/apb_vip/apb_if.sv`, `ip/photonic_ring_tuner/dv/optics/ring_if.sv`
2. `common/apb_vip/apb_vip_pkg.sv` then `ip/photonic_ring_tuner/dv/photonic_ring_tuner_pkg.sv`
3. `ip/photonic_ring_tuner/dv/optics/ring_model.sv`
4. `ip/photonic_ring_tuner/rtl/photonic_ring_tuner.sv`
5. `common/apb_vip/apb_protocol_checker.sv`, `ip/photonic_ring_tuner/rtl/photonic_ring_tuner_sva.sv`
   (plain-SVA modules, `bind`-ed in the tb top)
6. `ip/photonic_ring_tuner/tb/photonic_ring_tuner_tb_top.sv`

`+incdir` lines in `run.f` point at every directory holding a `.svh`.
Default APB widths (ADDR_WIDTH=8, DATA_WIDTH=32): the standalone build needs
**no** `+define+APB_ADDR_W`.

## Run locally

```
make -C ip/photonic_ring_tuner/sim questa TEST=photonic_ring_tuner_lock_test SEED=3
make -C ip/photonic_ring_tuner/sim vcs    TEST=photonic_ring_tuner_settle_short_test
make -C ip/photonic_ring_tuner/sim xrun   TEST=photonic_ring_tuner_reg_test
make -C ip/photonic_ring_tuner/sim regress        # all tests x 8 seeds (Questa)
```

| Test | Ring regime | What it proves |
|------|-------------|----------------|
| `photonic_ring_tuner_smoke_test`        | fixed mid-range | reset values, RW/RO/reserved/W1C behaviour |
| `photonic_ring_tuner_reg_test`          | fixed mid-range | `uvm_reg_hw_reset_seq` + `uvm_reg_bit_bash_seq` |
| `photonic_ring_tuner_error_test`        | fixed mid-range | unmapped/unaligned → `pslverr`; RO writes dropped |
| `photonic_ring_tuner_lock_test`         | LOCKABLE (random) | acquires from cold, lands ON resonance, holds, re-acquires |
| `photonic_ring_tuner_lock_loss_test`    | LOCKABLE (random) | acquires, then the lock is **broken on purpose** (laser off with the loop still enabled): `locked` must deassert, `ACTIVE` stay high, no error flag appear, and the loop re-acquire when the light returns |
| `photonic_ring_tuner_settle_short_test` | SLOW_THERMAL      | **SETTLE < tau ⇒ must NOT lock** (the headline bug) |
| `photonic_ring_tuner_dark_test`         | DARK              | laser off ⇒ `SWEEP_ERR`, never a false lock |
| `photonic_ring_tuner_rail_test`         | RAIL              | resonance past DAC_MAX ⇒ `RAIL_ERR`, saturate not wrap |
| `photonic_ring_tuner_rail_w1c_race_test`| RAIL              | W1C vs HW-set race on `RAIL_ERR` while still railing (spec §3.5) |
| `photonic_ring_tuner_ratio_test`        | LOCKABLE (random) | sweeps settle/tau + dither for the coverage cross |

Because the ring is randomized per seed, **one seed proves very little** — the
`regress` target runs every test across eight seeds, which is the minimum that
should be quoted as a result.

### Negative tests carry a liveness requirement

`settle_short`, `dark` and `rail` all assert something that *did not happen*
(`locked` never rose). A verdict of that shape is passed by a DUT that does
nothing at all — `locked` tied low, an FSM that never leaves `S_IDLE`, a dead
photodiode — so each of those tests additionally requires **positive evidence
that the loop ran**: `CTRL.EN` was seen to rise, `STATUS.ACTIVE` was read high,
`dac_code` visited at least half the DAC range, and (on a lit ring) the model
delivered a sample above `MINPOW` while the DUT's own `PD` register read
non-zero. Missing evidence is a `UVM_ERROR` (`SCB_NOT_LIVE` / `VSEQ_NOT_LIVE`),
not a silent pass. The mirror image applies to `lock_test`: the stability check
only counts if the lock was **held** for at least `stability_window/2` clocks.

## Run on EDA Playground

- Language: **SystemVerilog / UVM**, UVM version **1.2**.
- Tool: **Aldec Riviera-PRO** — full UVM/SVA support and the only UVM-capable
  simulator on Playground that needs no account validation. Questa / VCS /
  Xcelium work too, but require a pre-approved institutional email.
- Enable your simulator's **SVA** and **coverage** if you want the bound
  properties and covergroups reported.
- Run/plusargs field: `+UVM_TESTNAME=photonic_ring_tuner_lock_test` (or any test
  above).

Panes (EDA Playground has no `run.f`; paste files respecting the order above —
the site compiles the *Design* pane first, then *Testbench*):

- **Design** pane (RTL + interfaces + the model + plain SVA):
  `apb_if.sv`, `ring_if.sv`, `ring_model.sv`, `photonic_ring_tuner.sv`,
  `apb_protocol_checker.sv`, `photonic_ring_tuner_sva.sv`.
- **Testbench** pane (packages + tb, plus the `.svh` includes reachable via the
  include path): `apb_vip_pkg.sv` and its `.svh` files,
  `photonic_ring_tuner_pkg.sv` and all `dv/**/*.svh`, and
  `photonic_ring_tuner_tb_top.sv` last. Make sure the top module
  `photonic_ring_tuner_tb_top` is the elaboration top.

Note: the `bind` statements live in `photonic_ring_tuner_tb_top.sv`; the two SVA
modules must be compiled (Design pane) so the binds resolve.

## Design notes

- **RAL prediction is EXPLICIT**: a `uvm_reg_predictor#(apb_seq_item)` is fed by
  the APB monitor; `default_map.set_auto_predict(0)`. `STATUS`, `DAC` and `PD`
  are hardware-updated (volatile) — the mirror may desync, so all three carry
  `NO_REG_BIT_BASH_TEST` and their real behaviour is checked by the scoreboard.
  `STATUS` is per-**field** mixed (`LOCKED`/`ACTIVE` RO, `RAIL_ERR`/`SWEEP_ERR`
  W1C), and `STEP` / `LOCK_CFG` pack two independently programmable fields per
  word, so the RAL exercises field-level access policies, not register-level ones.
- **No cycle-exact reference model, on purpose.** The DUT's input is a
  continuous-valued function of its own output; a bit-exact predictor would have
  to re-implement the ring, the photodiode and the ADC rounding, and would then
  only be testing itself. The scoreboard instead checks **properties of the
  closed loop** — acquisition inside a deadline *derived from the programmed
  registers*, accuracy against the model's internal `detune_code`, stability of
  the DAC while locked, no false lock on a dark ring, and saturation-without-wrap
  at the rail.
- **Tolerances**: the only tolerance in the env is physical and explicit —
  `|detune_code| <= fwhm_code/2` for accuracy, and `span(dac_code) <=
  6*dither_eff` for stability (the spec's ±2·dither_eff on the internal `dac_q`
  plus the ±dither_eff probe excursion that is visible on the pin). Everything
  else — error flags, register readback, `pslverr` — is compared exactly.
- **The `RAIL_ERR` W1C race needs its own test.** `rail_vseq` and `dark_vseq`
  disable the loop before clearing their sticky flag, so the clear is
  deterministic — but hardware can then never re-set the bit and the spec-§5
  cover point `c_w1c_race_rail` is unreachable. `rail_w1c_race_vseq` keeps the
  loop enabled and railing (so `rail_set` fires once per fine iteration),
  shortens `SETTLE` to 4 and programs `THRESH = 0` so the loop can never call
  the rail "at peak", and hammers hundreds of jittered W1C writes at
  `STATUS.RAIL_ERR`. Software must not be able to clear a live hardware
  condition: the bit reads back set every time.
- **The negative tests are constrained to be deterministic.** Each regime in
  `ring_cfg` violates exactly one precondition of acquisition (thermal settling,
  light, reachability), with margins worked out in the constraint comments, so
  "must not lock" is a real assertion rather than a hopeful one. And because a
  purely negative assertion is passed by a DUT that does nothing, each of them
  is paired with the liveness evidence described above — `settle_short` in
  particular also requires that the coarse sweep did **not** end in `SWEEP_ERR`,
  so it can only pass by demonstrating the thermal-lag failure it claims rather
  than degenerating into the dark-ring case.
- **Coverage crosses are honest, not padded.** `x_ratio_outcome` and `x_step`
  both contain cells no stimulus in this suite can reach (the regime that
  produces an outcome also pins the settle/tau ratio; the suite only moves one
  `STEP` field off nominal at a time). Those cells carry `ignore_bins` with the
  reason stated inline, so the remaining percentage means something — while
  every `(ratio, locked)` cell stays in, because `(ratio < 1, locked)` appearing
  would be a finding.
