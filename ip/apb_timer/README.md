# `apb_timer` — programmable APB3 timer (RTL + UVM DV)

An APB3 peripheral: a prescaled 32-bit down-counter with one-shot/periodic modes and a
level interrupt. Small enough to read in one sitting, rich enough to exercise a complete
UVM environment.

- **Spec (the contract):** [`docs/apb_timer_spec.md`](docs/apb_timer_spec.md) — register
  map, counter/prescaler/IRQ behavior, and `PSLVERR` semantics.
- **Regression list:** [`docs/REGRESSION.md`](docs/REGRESSION.md) — the 9 tests,
  what each one proves, and how to run them.

## RTL (`rtl/`)
| File | Role |
|------|------|
| `apb_timer.sv` | The DUT — registers, prescaled down-counter, one-shot/periodic, level IRQ, PSLVERR |
| `apb_timer_sva.sv` | Bindable timer-specific SVA (irq level relation, sticky W1C, timeout covers) |

The reusable APB protocol checker lives in [`common/apb_vip/apb_protocol_checker.sv`](../../common/apb_vip/apb_protocol_checker.sv).

## DV (`dv/`)
| File | Role |
|------|------|
| `apb_timer_reg_block.svh` | RAL model (CTRL/LOAD/VALUE/STATUS/PRESCALE, exact policies) |
| `apb_timer_ref_model.svh` | Cycle-exact shadow of the timer (predicts reads + IRQ edges) |
| `apb_timer_scoreboard.svh` | In-order APB + IRQ checking with a zero-activity guard |
| `apb_timer_coverage.svh` | Functional coverage (fields, crosses, prescale/load bins, events) |
| `irq/` | Second, passive interrupt-line agent (if / item / monitor / agent) |
| `apb_timer_env.svh`, `apb_timer_env_cfg.svh` | Env assembly + config (RAL predictor wiring) |
| `seq/apb_timer_vseq_lib.svh` | Virtual sequences (smoke / oneshot / periodic / prescale / w1c / irq_mask / error / reg / rand) |
| `test/apb_timer_test_lib.svh` | Test library (one test per scenario) |
| `apb_timer_pkg.sv` | Compilation package (imports the reused `apb_vip_pkg`) |

The APB agent, sequencer, adapter, coverage and sequence library are **reused** from
[`common/apb_vip`](../../common/apb_vip).

## Run
See [`sim/README.md`](sim/README.md). Quick start:
```sh
make -C sim questa TEST=apb_timer_oneshot_test     # or vcs / xrun
make -C sim regress                                # all tests x multiple seeds
```
