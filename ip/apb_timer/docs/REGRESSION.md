# `apb_timer` — Regression List

The block-level test suite. Every test extends `apb_timer_base_test`, which
builds the ACTIVE APB agent + the PASSIVE IRQ agent + the RAL, then runs one
virtual sequence on the APB sequencer. `start_vseq()` waits for reset release,
raises the objection, and leaves a 200 ns drain window so trailing IRQ edges
still reach the scoreboard. See [`apb_timer_spec.md`](apb_timer_spec.md) for the
register map.

Standard UVM-1.2 / IEEE 1800.2. Full UVM runs on EDA Playground (commercial
sims); RTL + plain-SVA are syntax/lint-gated locally with Verible.

Default widths (ADDR=8, DATA=32) — no `APB_ADDR_W` define needed at this level.

---

## Tests

| # | Test (`+UVM_TESTNAME=`) | Virtual sequence | What it exercises | Primary checkers |
|---|-------------------------|------------------|-------------------|------------------|
| 1 | `apb_timer_smoke_test` | `smoke_vseq` | Reset values, then RW readback of `CTRL`/`LOAD`/`PRESCALE` with `EN=0` so nothing counts. Full-width compares also prove reserved bits read back 0. | RAL mirror compare, scoreboard |
| 2 | `apb_timer_oneshot_test` **(flagship)** | `oneshot_vseq` *(randomized)* | One-shot timeout end-to-end: `EN=1, MODE=0, IRQ_EN=1`, wait `load*(presc+1)` ticks, check `STATUS.IRQ` set, `EN` **auto-cleared**, then W1C-clear and confirm `irq` drops. | cycle-exact ref-model scoreboard, `a_irq_level`, `a_irq_deassert` |
| 3 | `apb_timer_periodic_test` | `periodic_vseq` *(randomized)* | `MODE=1`: repeated reloads and repeated IRQ assertions without re-arming; `EN` stays set across timeouts. | ref-model scoreboard, `a_irq_level` |
| 4 | `apb_timer_prescale_test` | `prescale_vseq` | Non-zero `PRESCALE`: the tick divider stretches the timeout by exactly `presc+1`. | ref-model scoreboard (cycle-exact tick model) |
| 5 | `apb_timer_w1c_test` | `w1c_vseq` | `STATUS.IRQ` W1C semantics: writing 0 must **not** clear, writing 1 clears; plus a **HW-set-wins race** — `LOAD=0, PRESCALE=0` times out every cycle while W1C writes are hammered, so some sets land on the same clock as the clear and the flag stays set. | `a_status_sticky`, ref model, `cg_evt.w1c_race` coverage |
| 6 | `apb_timer_irq_mask_test` | `irq_mask_vseq` | Mask/unmask of a **pending** flag: arm masked (`IRQ_EN=0`) → `irq` low; unmask with `EN=0` → `irq` rises on the mask change alone; re-mask → `irq` drops but flag stays sticky; unmask + W1C → both drop. | `a_irq_level`, `a_irq_deassert`, `a_status_sticky` |
| 7 | `apb_timer_error_test` | `error_vseq` | Unmapped read/write and an unaligned read (`0x03`) must raise PSLVERR; a legal write to RO `VALUE` must **not** error and must have no effect. | scoreboard decode checks, `apb_protocol_checker` |
| 8 | `apb_timer_reg_test` | `reg_hw_reset_vseq` | RAL hw-reset + bit-bash. `CTRL` is excluded (self-clearing `EN` would false-mismatch), `VALUE` is RO (skipped), `STATUS` W1C is bashed safely with `EN=0`. | RAL predictor / mirror compare |
| 9 | `apb_timer_rand_test` | `rand_vseq` *(randomized)* | Randomized mixed traffic: register churn, short one-shots left to expire, error accesses. | all of the above + functional coverage |

---

## Regression matrix

`make regress` runs the full cross on Questa:

| | |
|---|---|
| **Tests** (9) | smoke, oneshot, periodic, prescale, w1c, irq_mask, error, reg, rand |
| **Seeds** (5) | 1, 2, 3, 4, 5 |
| **Total runs** | **45** |

Only tests 2, 3 and 9 randomize their vseq, so seed sweeping buys the most on
those; the rest are directed and seed-stable by construction.

---

## How to run

### Locally (with a licensed simulator)

```sh
# single test on a chosen simulator + seed
make -C ip/apb_timer/sim questa TEST=apb_timer_oneshot_test SEED=3
make -C ip/apb_timer/sim vcs    TEST=apb_timer_periodic_test SEED=7
make -C ip/apb_timer/sim xrun   TEST=apb_timer_reg_test

# full multi-seed regression (9 tests x 5 seeds, Questa)
make -C ip/apb_timer/sim regress
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
3. Paste the sources in `run.f` compile order: interfaces → packages → RTL → SVA
   → `tb/apb_timer_tb_top.sv`.

See [`../sim/README.md`](../sim/README.md) for the exact pane-by-pane setup.
