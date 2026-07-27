# `photonic_ring_tuner` — Regression List

The block-level test suite. Every test extends `photonic_ring_tuner_base_test`,
which builds the ACTIVE APB agent + the RAL + a **randomized `ring_cfg`**, then
runs one virtual sequence. Unlike `apb_timer` and `apb_gpio`, this env has no
second *agent*: the optical side is a **closed loop**, so the ring is configured
rather than driven. `ring_cfg` is randomized in `build_phase` (reproducible from
the UVM seed, and printed before anything runs) and applied to `ring_if` in
`start_of_simulation_phase`, i.e. before reset is released. `start_vseq()` waits
for reset release, raises the objection, and leaves a 500 ns drain window so the
last optical cycles reach the scoreboard.

A derived test customises three things: the **ring regime** (which physical
situation to randomize into), the **expected outcome** (what the scoreboard must
prove), and the vseq. Each regime is constrained so it violates exactly one
precondition of acquisition — thermal settling, light, or reachability — which
is what makes the negative tests self-checking rather than hopeful. See
[`photonic_ring_tuner_spec.md`](photonic_ring_tuner_spec.md) for the register
map and §7.5 for the five scoreboard checks.

**Negative outcomes carry a liveness requirement.** Three of these tests assert
that something did *not* happen (`locked` never rose). A verdict of that shape
is passed by a DUT that does nothing at all — `locked` tied low, an FSM that
never leaves `S_IDLE`, a dead photodiode — so it proves nothing on its own.
Every test with an optical verdict therefore also demands **positive evidence
that the loop ran**: `CTRL.EN` observed rising, `STATUS.ACTIVE` read high,
`dac_code` spanning at least half the DAC range, and — on a lit ring — a model
sample above `MINPOW` together with a non-zero `PD` readback. Missing evidence
is a `UVM_ERROR` (`SCB_NOT_LIVE` / `VSEQ_NOT_LIVE`), never a quiet pass. The
same reasoning is applied to the positive side: `lock_test`'s stability check
only counts if the lock was actually *held* for `stability_window/2` clocks.

Standard UVM-1.2 / IEEE 1800.2. Full UVM runs on EDA Playground (commercial
sims); RTL + plain-SVA are syntax/lint-gated locally with Verible.

Default widths (ADDR=8, DATA=32; DAC=12, ADC=12) — no `APB_ADDR_W` define needed
at this level.

---

## Tests

| # | Test (`+UVM_TESTNAME=`) | Virtual sequence | Ring regime | What it exercises | Primary checkers |
|---|-------------------------|------------------|-------------|-------------------|------------------|
| 1 | `photonic_ring_tuner_smoke_test` | `smoke_vseq` | `DEFAULT` (fixed mid-range) | Reset values of all seven registers; RW readback of the packed multi-field registers (`STEP`, `LOCK_CFG`); reserved bits read 0 and ignore writes; writes to RO `DAC`/`PD` silently dropped (**no** `pslverr`); W1C on an idle `STATUS` is a no-op. The loop is never enabled. | RAL mirror compare, scoreboard |
| 2 | `photonic_ring_tuner_reg_test` | `reg_vseq` | `DEFAULT` | `uvm_reg_hw_reset_seq` + `uvm_reg_bit_bash_seq` over the block. `STATUS`, `DAC` and `PD` carry both `NO_REG_BIT_BASH_TEST` and `NO_REG_HW_RESET_TEST`, and their live fields are `set_compare(UVM_NO_CHECK)` — all three are hardware-updated, so neither a walking-ones readback nor a reset compare models them. **The loop is *not* disabled throughout**: bit-bash bashes `CTRL` like any other RW register and therefore *does* write `EN = 1` for one beat, starting a real acquisition. That is benign only because `SETTLE` is still 32, so the FSM is still counting settle clocks in `S_SWEEP_WAIT` when the very next bus operation clears `EN` — no ADC sample is ever taken and `dac_q` never advances. The vseq proves it rather than assuming it: it re-reads `STATUS == 0` and `DAC == 0` at the end. | RAL predictor / mirror compare, end-of-vseq `STATUS`/`DAC` readback |
| 3 | `photonic_ring_tuner_error_test` | `error_vseq` | `DEFAULT` | Unmapped read (`0x1C`, just past `PD`), unaligned read (`0x06`) and an unmapped write (`0xFC`) must raise `PSLVERR` with `prdata = 0`; a legal write to RO `DAC` must **not** error and must have no effect. | scoreboard decode checks, `apb_protocol_checker` |
| 4 | `photonic_ring_tuner_lock_test` **(flagship)** | `lock_vseq` | `LOCKABLE` *(randomized)* | Cold acquisition on a randomized reachable ring using the **default** register settings: sweep → dither → `locked`, hold across the stability window, then the register view of a locked loop (`STATUS.LOCKED \| ACTIVE`), then disable and **re-acquire**. The heater holds its bias while disabled (spec §3.1), so the re-acquisition starts hot — the opposite initial detuning sign to the cold start, and the other half of the sign coverpoint. | Scoreboard checks 1–3: acquisition inside the derived deadline, `\|detune_code\| <= fwhm/2`, `span(dac_code) <= 6·dither_eff`; `p_locked_port`, `p_probe_hi_ge_centre`, `p_settle_honoured` |
| 5 | `photonic_ring_tuner_settle_short_test` **(the headline case)** | `settle_short_vseq` *(randomized)* | `SLOW_THERMAL` | `SETTLE` = 1–2 clocks against a `tau` of 400–800 clocks (ratio ≈ 0.002): the controller samples the photodiode long before the ring has reached the commanded temperature, so the coarse sweep records its peak offset by the whole thermal lag and the fine loop engages on the wrong side of the resonance. **`locked` must never rise** — the `MINPOW` term is the only thing between this and a confident, completely wrong lock. Watched for twice the acquisition deadline, with the failing cycle reported in the log as it happens. **Plus a liveness requirement**, because "`locked` never rose" on its own is passed by a DUT that does nothing: the run must also show `CTRL.EN` rising, `STATUS.ACTIVE` read high, `dac_code` spanning at least half the DAC range, the model presenting a sample ≥ `MINPOW`, a non-zero `PD` read, and **no `SWEEP_ERR`** (otherwise the run degenerated into the dark-ring result and never reached the thermal-lag failure it claims). | Scoreboard check 4 (`RING_EXP_NO_LOCK`) **+ `check_loop_ran`**, `observe_no_lock` + `assert_loop_ran`, `p_no_lock_without_power` |
| 6 | `photonic_ring_tuner_dark_test` | `dark_vseq` | `DARK` (`laser_on = 0`) | Dark fibre: the photodiode reads noise only, so the sweep finds nothing above `MINPOW` anywhere in the tuning range → `SWEEP_ERR`. **The false-lock case**: far off resonance both dither probes are equal (≈ 0), so a gradient-only lock rule would declare lock here. Then W1C semantics on the sticky flag — writing 0 has no effect, writing 1 clears. | Scoreboard check 4 (`RING_EXP_SWEEP_ERR`), `p_no_lock_without_power` / `p_no_lock_when_dark`, `p_sweep_err_sticky` |
| 7 | `photonic_ring_tuner_rail_test` | `rail_vseq` | `RAIL` | Resonance parked just beyond `DAC_MAX`, close enough that the last sweep point still sees light (so the sweep succeeds and the fine loop actually engages) but on the steep flank, so the loop says "hotter" every iteration. The DAC must **saturate at `DAC_MAX`, never wrap** — the classic integrator-windup signature — `RAIL_ERR` must set and stay set until W1C, and `locked` must not rise. | Scoreboard check 5 (`RING_EXP_RAIL_ERR`), `p_dac_never_wraps`, `p_rail_sticky` |
| 8 | `photonic_ring_tuner_ratio_test` | `ratio_vseq` *(randomized)* | `LOCKABLE` *(randomized)* | Coverage filler with **no optical verdict** (`RING_EXP_NONE`): programs `SETTLE` as a randomized multiple of the ring's `tau` so the settle/tau bins `{<1, 1–2, 2–4, >4}` all fill, and randomizes `DITHER` so the dither/linewidth coverpoint fills too. The point of the cross is to *show* which ratios acquire and which do not, so the outcome is recorded rather than asserted — and consistently with that, scoreboard checks 2 (accuracy) and 3 (stability) are **latched and reported but not escalated** here, so a test documented as having no optical verdict cannot fail on one. | functional coverage (`cg_acq.x_ratio_outcome`), bound SVA |
| 9 | `photonic_ring_tuner_rail_w1c_race_test` | `rail_w1c_race_vseq` | `RAIL` | Directed hit on the **W1C-vs-HW-set race** of spec §3.5, added because the `c_w1c_race_rail` cover point was otherwise **unreachable**: tests 6 and 7 both disable the loop before clearing the flag, so hardware can never re-set it in the same clock. Here the loop stays *enabled* and railed, so `rail_err_q` re-asserts every fine iteration (`SETTLE`=4 and `THRESH`=0 shorten that iteration to ~13 clocks and keep `move_up` permanently true), while a few hundred phase-jittered W1C writes collide with it. HW-set must win: the bit still reads 1 after the clear. | Scoreboard check 5 (`RING_EXP_RAIL_ERR`), `p_rail_sticky`, cover `c_w1c_race_rail` |
| 10 | `photonic_ring_tuner_lock_loss_test` | `lock_loss_vseq` | `LOCKABLE` *(randomized)* | Directed **lock loss**, added because `cg_acq.cp_outcome.lost_lock` (spec §7.6 and the §5 cover list) was otherwise **unfillable**: nothing else disturbs an established lock, and in `lock_test` a lost lock is itself a `UVM_ERROR`. Here the loop acquires and holds, then the fibre goes **dark with the loop still enabled**. Both probes collapse below `MINPOW`, so spec §3.4 requires `locked` to deassert within one fine iteration — `locked_q` is a live status, not a sticky bit. Checked: `locked` falls, `STATUS.LOCKED` clears, `STATUS.ACTIVE` stays high (losing lock must not stop the loop), no sticky error flag is invented, `dac_q` does not walk away while dark (noise ≤ 2 LSB against `THRESH` = 8), and the loop **re-acquires without a re-sweep** when the light returns. | Scoreboard `RING_EXP_LOCK_THEN_LOSS` (the loss is *required*, not flagged), cover `c_lock_lost`, `cg_acq.cp_outcome.lost_lock` |

---

## Regression matrix

`make regress` runs the full cross on Questa:

| | |
|---|---|
| **Tests** (10) | smoke, reg, error, lock, settle_short, dark, rail, ratio, rail_w1c_race, lock_loss |
| **Seeds** (8) | 1, 2, 3, 4, 5, 6, 7, 8 |
| **Total runs** | **80** |

Eight seeds rather than the five used by `apb_timer`/`apb_gpio`, because the
optical tests are constrained-*random* in a way those are not: the ring itself
is randomized per seed, so tests 4–10 are a different physical problem on every
run and a single seed proves very little. Tests 1–3 are directed and
seed-stable.

The headline coverage item is `cg_acq.x_ratio_outcome` — the settle/tau ratio
crossed with the lock outcome. **Every `(ratio, locked)` cell stays in**, in
particular `(ratio < 1, locked)`: that cell's appearance would be a finding, so
it must never be hidden behind an `ignore_bins`.

What *is* excluded, with the reason stated at each `ignore_bins`, are cells no
stimulus in this suite can reach, because the regime that produces the outcome
also pins the ratio: `sweep_err` only comes from the DARK regime and `lost_lock`
only from `lock_loss_test`, both of which run at the default `SETTLE` = 32
against `tau ≤ 8` — i.e. always at ratio ≥ 4. The same applies to `cg_step`'s
`x_step` cross, where the suite only ever moves one of `DITHER`/`SWEEP` off its
nominal band at a time. Leaving structurally unreachable cells in the
denominator would make the reported percentage a lie by omission; excluding them
(and *only* them) is what makes the remaining number mean something.

---

## Results

**Not filled in.** No simulator is installed on this machine — the UVM
environments in this repository are compiled and run on EDA Playground
(Aldec Riviera-PRO), and the RTL and plain-SVA are the only parts gated locally
(Verible syntax + lint). Nothing in this suite has been simulated yet, so no
pass/fail status, coverage figure, or bug count is claimed here. This document
is the regression *plan*; the results column will be added once the suite has
been run.

---

## How to run

### Locally (with a licensed simulator)

```sh
# single test on a chosen simulator + seed
make -C ip/photonic_ring_tuner/sim questa TEST=photonic_ring_tuner_lock_test SEED=3
make -C ip/photonic_ring_tuner/sim vcs    TEST=photonic_ring_tuner_settle_short_test SEED=7
make -C ip/photonic_ring_tuner/sim xrun   TEST=photonic_ring_tuner_reg_test

# full multi-seed regression (10 tests x 8 seeds, Questa)
make -C ip/photonic_ring_tuner/sim regress
```

Targets `cd` to the repo root first, because [`../sim/run.f`](../sim/run.f)
uses repo-root-relative paths.

### On EDA Playground

1. Left pane: choose UVM **1.2** and a simulator. **Aldec Riviera-PRO** is the one
   to pick — it is a full commercial SystemVerilog/UVM/SVA simulator and is the
   only UVM-capable choice that needs *no account validation*, so anyone with a
   Google login can run this suite. Questa / VCS / Xcelium also work but are
   gated behind a pre-approved (institutional) email address.
2. Select the test with `+UVM_TESTNAME=<test from the table>`.
3. Paste the sources in `run.f` compile order: interfaces (`apb_if`, `ring_if`)
   → packages → **the optical model** (`ring_model.sv`) → RTL → SVA →
   `tb/photonic_ring_tuner_tb_top.sv`.
4. Enable your simulator's SVA and coverage if you want the bound properties and
   the covergroups reported.

`ring_model.sv` is `real`-valued and deliberately non-synthesizable; it belongs
to the Design pane only so the `bind`s and the loop resolve, never to a
synthesis flow.

See [`../sim/README.md`](../sim/README.md) for the exact pane-by-pane setup.
