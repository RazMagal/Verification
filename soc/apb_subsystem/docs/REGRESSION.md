# `apb_subsystem` — Regression List

The subsystem test suite. Every test extends `apb_subsystem_base_test`, which
builds the ACTIVE upstream agent + two PASSIVE per-timer environments + the
hierarchical RAL, then runs one virtual sequence on the subsystem virtual
sequencer. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the component picture.

Standard UVM-1.2 / IEEE 1800.2. Full UVM runs on EDA Playground (commercial
sims); RTL + plain-SVA are syntax/lint-gated locally with Verible.

---

## Tests

| # | Test (`+UVM_TESTNAME=`) | Virtual sequence | What it exercises | Primary checkers |
|---|-------------------------|------------------|-------------------|------------------|
| 1 | `apb_subsystem_smoke_test` | `smoke_vseq` | Reset-value + RW readback across **both** reused timer blocks and one memory word — reuse sanity / connectivity. | RAL mirror compare, per-timer scoreboards |
| 2 | `apb_subsystem_concurrent_timers_test` **(flagship)** | `concurrent_timers_vseq` | Both timers programmed **differently** and enabled together; the two IRQs are checked **independent and correct**. | 2× nested cycle-exact ref-model scoreboards, `apb_timer_sva`, `apb_protocol_checker` |
| 3 | `apb_subsystem_mem_test` | `mem_vseq` | Write/readback walk across the 64-word memory region. | subsystem scoreboard memory shadow |
| 4 | `apb_subsystem_decode_error_test` | `decode_error_vseq` | Unmapped pages **and** illegal timer offsets must raise PSLVERR; legal accesses must not. | subsystem scoreboard decode checks, `apb_protocol_checker` |
| 5 | `apb_subsystem_rand_test` | `rand_vseq` | Randomized mixed-page traffic (timers, memory, decode errors, short timeouts). | all of the above + functional coverage |

Every vseq touches both timers at least once so the per-timer sub-scoreboards
clear their no-activity guard even in the memory/decode-only tests.

---

## Regression matrix

`make regress` runs the full cross on Questa:

| | Seeds |
|---|---|
| **Tests** (5) | smoke, concurrent_timers, mem, decode_error, rand |
| **Seeds** (5) | 1, 2, 3, 4, 5 |
| **Total runs** | **25** |

---

## How to run

### Locally (with a licensed simulator)

The build compiles the shared VIP, the whole `apb_timer` IP DV, and the thin
subsystem layer from one filelist. `+define+APB_ADDR_W=12` is already in
[`../sim/run.f`](../sim/run.f), and every Makefile target re-asserts it so the
entire build is a uniform 12-bit APB.

```sh
# single test on a chosen simulator + seed
make -C soc/apb_subsystem/sim questa TEST=apb_subsystem_concurrent_timers_test SEED=3
make -C soc/apb_subsystem/sim vcs    TEST=apb_subsystem_mem_test              SEED=7
make -C soc/apb_subsystem/sim xrun   TEST=apb_subsystem_decode_error_test

# full multi-seed regression (5 tests x 5 seeds, Questa)
make -C soc/apb_subsystem/sim regress
```

### On EDA Playground

1. Left pane: choose UVM 1.2 and a commercial simulator (Questa / VCS / Xcelium).
2. Compile/run options: add `+define+APB_ADDR_W=12` (or paste the contents of
   `sim/run.f`) and select the test with `+UVM_TESTNAME=<test from the table>`.
3. Paste the sources in `run.f` compile order: interfaces → packages → RTL → SVA
   → `tb/apb_subsystem_tb_top.sv`.

See [`../sim/README.md`](../sim/README.md) for the exact pane-by-pane setup.
