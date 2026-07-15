# `apb_gpio` — general-purpose parallel I/O (RTL + UVM DV)

An APB3 peripheral: `DATA_WIDTH` bidirectional-style GPIO pins with per-pin
direction, a synchronized input path, and per-pin rising-edge interrupts. A second
IP that **reuses the same APB VIP** as `apb_timer` but exercises a different
surface — pin I/O, a 2-flop input synchronizer, and edge-triggered interrupts.

- **Spec (the contract):** [`docs/apb_gpio_spec.md`](docs/apb_gpio_spec.md) — port
  list, register map, output/synchronizer/interrupt behavior, and the internal
  signal names the bound SVA and reference model rely on.

## RTL (`rtl/`)
| File | Role |
|------|------|
| `apb_gpio.sv` | The DUT — `DATA_OUT`/`DIR`/`INT_EN` (RW), `DATA_IN` (RO, synchronized), `INT_STATUS` (W1C); 2-FF input synchronizer; per-pin rising-edge interrupt; `irq = \|(INT_STATUS & INT_EN)`; PSLVERR on unmapped access |
| `apb_gpio_sva.sv` | Bindable gpio-specific SVA (`gpio_oe==DIR`, `gpio_out==DATA_OUT`, irq level relation, per-pin sticky `INT_STATUS`) |

The reusable APB protocol checker lives in [`common/apb_vip/apb_protocol_checker.sv`](../../common/apb_vip/apb_protocol_checker.sv).

## DV (`dv/`)
| File | Role |
|------|------|
| `apb_gpio_reg_block.svh` | RAL model (DATA_OUT/DATA_IN/DIR/INT_STATUS/INT_EN with exact RW/RO/W1C policies) |
| `apb_gpio_ref_model.svh` | Cycle-exact shadow: models the 2-FF sync + edge detect so `DATA_IN` readback and each `INT_STATUS` set line up bit- and cycle-exactly |
| `apb_gpio_scoreboard.svh` | In-order APB + pin-output checking, exact compares (no tolerance) |
| `apb_gpio_coverage.svh` | Functional coverage (DIR/INT_EN patterns, edge/irq/W1C-race events, pslverr) |
| `pin/` | Second, **active** pin agent (if / item / driver / monitor / agent) that drives `gpio_in` and observes `gpio_out`/`gpio_oe`/`irq` |
| `apb_gpio_env.svh`, `apb_gpio_env_cfg.svh` | Env assembly + config (RAL predictor wiring) |
| `seq/apb_gpio_vseq_lib.svh` | Virtual sequences (smoke / output_drive / input_capture / interrupt / w1c / error / reg / rand) |
| `test/apb_gpio_test_lib.svh` | Test library (one test per scenario) |
| `apb_gpio_pkg.sv` | Compilation package (imports the reused `apb_vip_pkg`) |

The APB agent, sequencer, adapter, coverage and sequence library are **reused** from
[`common/apb_vip`](../../common/apb_vip).

## Run
See [`sim/README.md`](sim/README.md). Quick start (standalone build — no width define needed):
```sh
make -C sim questa TEST=apb_gpio_interrupt_test     # or vcs / xrun
make -C sim regress                                 # all tests x multiple seeds
```
