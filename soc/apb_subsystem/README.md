# `apb_subsystem` — APB interconnect + 2×timer + memory (RTL + UVM DV)

A larger design whose verification is built almost entirely by **reuse** of the
[`apb_timer`](../../ip/apb_timer) IP and the [`common/apb_vip`](../../common/apb_vip) VIP.

```
             ┌──────────────── apb_subsystem ────────────────┐
 APB3 (12b) ─▶│ apb_interconnect  (decode paddr[11:8])        │
             │   ├─ 0x000 ─▶ apb_timer (timer0) ─▶ irq0       │
             │   ├─ 0x100 ─▶ apb_timer (timer1) ─▶ irq1       │
             │   ├─ 0x200 ─▶ apb_mem_slave                    │
             │   └─ else   ─▶ PSLVERR                         │
             └───────────────────────────────────────────────┘
```

## RTL (`rtl/`)
| File | Role |
|------|------|
| `apb_interconnect.sv` | Combinational 1→3 APB fabric: decode, per-slave psel/penable, response mux, unmapped→PSLVERR |
| `apb_mem_slave.sv` | Simple single-cycle APB memory slave |
| `apb_subsystem.sv` | Top: interconnect + 2× `apb_timer` + memory, uniform 12-bit `apb_if` |

## DV (`dv/`) — what is reused vs. new
**Reused** (imported via `apb_timer_pkg` / `apb_vip_pkg`): the APB agent + adapter +
coverage, and per timer the whole `apb_timer_env` nested in **passive** mode
(monitor + reference model + scoreboard + IRQ agent), plus the `apb_timer_reg_block`
instanced twice in the hierarchical register model.

**New (thin subsystem layer):**
| File | Role |
|------|------|
| `apb_subsystem_reg_block.svh` | Hierarchical RAL: two timer sub-blocks (0x000/0x100) + a `uvm_mem` (0x200) |
| `apb_subsystem_env.svh` | One active upstream agent + two nested passive timer envs + top predictor |
| `apb_subsystem_scoreboard.svh` | Memory shadow + decode-error (unmapped→PSLVERR) checks |
| `apb_subsystem_virtual_sequencer.svh`, `seq/apb_subsystem_vseq_lib.svh` | Virtual seqr + vseqs (smoke / concurrent-timers / mem / decode_error / rand) |
| `apb_subsystem_coverage.svh`, `apb_subsystem_env_cfg.svh` | Subsystem coverage + env config |
| `test/apb_subsystem_test_lib.svh`, `apb_subsystem_pkg.sv` | Tests + compilation package |

## Run
See [`sim/README.md`](sim/README.md). The build compiles the VIP at 12-bit
(`+define+APB_ADDR_W=12`, already in `sim/run.f`).
```sh
make -C sim xrun TEST=apb_subsystem_concurrent_timers_test    # or questa / vcs
make -C sim regress
```
