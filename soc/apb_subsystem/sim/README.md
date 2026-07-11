# apb_subsystem UVM environment

Verifies `apb_subsystem` (two `apb_timer` instances + a memory slave behind an
`apb_interconnect`, 12-bit APB) by **reusing** the shared APB VIP and the entire
`apb_timer` IP DV. Only the thin subsystem composition under
`soc/apb_subsystem/dv` is new.

## What is reused (unmodified)
- `common/apb_vip` — `apb_agent` (active upstream + passive per-timer),
  `apb_reg_adapter`, `apb_sequencer`, `apb_read_seq`/`apb_write_seq`,
  `apb_coverage`, `apb_protocol_checker` (bound onto every `apb_if`).
- `ip/apb_timer/dv` — `apb_timer_reg_block` (instanced **twice** in the
  hierarchical RAL), and the reused **`apb_timer_env` nested passively per timer**
  (its `apb_timer_ref_model` + `apb_timer_scoreboard` + `timer_irq_agent` +
  `apb_timer_coverage` do the exact behavioral checking of each timer).
- `ip/apb_timer/rtl/apb_timer_sva.sv` — bound onto **both** timer instances.

## The `+define+APB_ADDR_W=12` (required)
The VIP's `virtual apb_if` handles are unparameterized: their width follows the
`APB_ADDR_W` macro. This subsystem drives a 12-bit bus, and every internal
`apb_if` instance (`t0_if`/`t1_if`/`mem_if`) is 12-bit, so the whole build MUST
compile with `+define+APB_ADDR_W=12`. It is the first line of `run.f` and is also
passed explicitly by every Makefile target.

## Address map (decode `paddr[11:8]`)
| page | base  | slave  |
|------|-------|--------|
| 0x0  | 0x000 | timer0 (irq0) |
| 0x1  | 0x100 | timer1 (irq1) |
| 0x2  | 0x200 | mem (64 words) |
| else | —     | fabric `pslverr` |

## Run locally
From `soc/apb_subsystem/sim` (targets `cd` to the repo root themselves):

```
make questa TEST=apb_subsystem_smoke_test
make questa TEST=apb_subsystem_concurrent_timers_test   # flagship
make vcs    TEST=apb_subsystem_mem_test SEED=7
make xrun   TEST=apb_subsystem_decode_error_test
make regress                                            # all tests x 5 seeds
```

Tests: `apb_subsystem_smoke_test`, `apb_subsystem_concurrent_timers_test`
(both timers programmed differently, enabled together, both IRQs verified
independently), `apb_subsystem_mem_test`, `apb_subsystem_decode_error_test`,
`apb_subsystem_rand_test`.

## EDA Playground
1. Tool: a UVM-1.2 simulator (Aldec Riviera-PRO / Mentor Questa / Synopsys VCS).
2. Testbench+Design: paste the sources in `run.f` order. Add the compile option
   **`+define+APB_ADDR_W=12`** (Playground "SystemVerilog/Verilog compile
   options" box) and enable UVM.
3. Reuse sources come from `common/apb_vip/*` and `ip/apb_timer/dv/*` +
   `ip/apb_timer/rtl/apb_timer*.sv`; only `soc/apb_subsystem/*` is subsystem-new.
4. Run-time plusargs: `+UVM_TESTNAME=apb_subsystem_concurrent_timers_test`
   (top module `apb_subsystem_tb_top`).
