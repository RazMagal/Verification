# `apb_gpio` — Regression List

The block-level test suite. Every test extends `apb_gpio_base_test`, which
builds the ACTIVE APB agent + the **ACTIVE pin agent** (`gpio_if`) + the RAL,
then runs one virtual sequence. Unlike `apb_timer`, this env drives a second
interface: `start_vseq()` wires both the APB sequencer and the pin sequencer
into the vseq, so stimulus can come from the bus and the pins *concurrently*.
A 200 ns drain window lets trailing pin/IRQ events reach the scoreboard.
See [`apb_gpio_spec.md`](apb_gpio_spec.md) for the register map.

Standard UVM-1.2 / IEEE 1800.2. Full UVM runs on EDA Playground (commercial
sims); RTL + plain-SVA are syntax/lint-gated locally with Verible.

Default widths (ADDR=8, DATA=32) — no `APB_ADDR_W` define needed at this level.

---

## Tests

| # | Test (`+UVM_TESTNAME=`) | Virtual sequence | What it exercises | Primary checkers |
|---|-------------------------|------------------|-------------------|------------------|
| 1 | `apb_gpio_smoke_test` | `smoke_vseq` | Reset values, RW readback of `DATA_OUT`/`DIR`/`INT_EN`, RO `DATA_IN` (writes silently dropped, stays 0), W1C `INT_STATUS` with nothing pending. | RAL mirror compare, scoreboard |
| 2 | `apb_gpio_output_drive_test` | `output_drive_vseq` | `DIR` selects per-pin output enable and `DATA_OUT` reaches the pads: `gpio_oe` must track `DIR` and `gpio_out` must track `DATA_OUT`, bit by bit. | `a_oe_follows_dir`, `a_out_follows_dout`, ref-model scoreboard |
| 3 | `apb_gpio_input_capture_test` | `input_capture_vseq` *(randomized)* | Externally driven pins propagate through **both** synchronizer flops into `DATA_IN`; pattern changes and per-pin set/clear are tracked. | ref-model scoreboard (2-FF sync model), pin monitor |
| 4 | `apb_gpio_interrupt_test` **(flagship)** | `interrupt_vseq` | Full edge-detect + mask lifecycle: arm a flag while **masked** (`irq` stays low) → unmask and `irq` rises with **no new edge** → re-mask, `irq` drops but the flag stays sticky → unmask + W1C, both drop → multi-pin edges with a full enable mask. | `a_irq_level`, `a_intstat_sticky`, ref-model scoreboard |
| 5 | `apb_gpio_w1c_test` | `w1c_vseq` (+ `pin_toggle_seq`) | `INT_STATUS` W1C semantics, then a **HW-set-wins race**: `pin_toggle_seq` generates fresh rising edges on the *pin* sequencer while W1C writes hammer bit 0 on the *APB* sequencer. The 2-FF synchronizer jitters the HW set against the ACCESS beats, so some sets coincide with a clear — the flag must stay set. Independent sequencers, so no arbitration conflict. | `a_intstat_sticky`, ref model, `cg_evt.w1c_race` coverage |
| 6 | `apb_gpio_error_test` | `error_vseq` | Unmapped read (`0x14`, just past `INT_EN`), unaligned read (`0x02`) and unmapped write must raise PSLVERR; a legal write to RO `DATA_IN` must **not** error and must leave it 0. | scoreboard decode checks, `apb_protocol_checker` |
| 7 | `apb_gpio_reg_test` | `reg_vseq` | `uvm_reg_hw_reset_seq` + `uvm_reg_bit_bash_seq` over the whole block. Inputs are held low (`clear_pins`) for the walk so pin activity can't set `INT_STATUS` mid-bash and false-mismatch. | RAL predictor / mirror compare |
| 8 | `apb_gpio_rand_test` | `rand_vseq` *(randomized)* | 12–24 randomized ops mixing register churn (including random W1C) with pin drive/set/toggle, then a settle phase that quiesces the pins and clears pending flags. | all of the above + functional coverage |

---

## Regression matrix

`make regress` runs the full cross on Questa:

| | |
|---|---|
| **Tests** (8) | smoke, output_drive, input_capture, interrupt, w1c, error, reg, rand |
| **Seeds** (5) | 1, 2, 3, 4, 5 |
| **Total runs** | **40** |

Tests 3 and 8 randomize their vseq and test 5 races two sequencers, so seed
sweeping buys the most on those three; the rest are directed and seed-stable.

---

## How to run

### Locally (with a licensed simulator)

```sh
# single test on a chosen simulator + seed
make -C ip/apb_gpio/sim questa TEST=apb_gpio_interrupt_test SEED=3
make -C ip/apb_gpio/sim vcs    TEST=apb_gpio_input_capture_test SEED=7
make -C ip/apb_gpio/sim xrun   TEST=apb_gpio_reg_test

# full multi-seed regression (8 tests x 5 seeds, Questa)
make -C ip/apb_gpio/sim regress
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
3. Paste the sources in `run.f` compile order: interfaces (`apb_if`, `gpio_if`)
   → packages → RTL → SVA → `tb/apb_gpio_tb_top.sv`.

See [`../sim/README.md`](../sim/README.md) for the exact pane-by-pane setup.
