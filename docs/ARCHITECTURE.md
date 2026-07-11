# Architecture & Verification Strategy

This repository is a compact but complete demonstration of a modern
**UVM / SystemVerilog** verification flow: design a peripheral, verify it with a
reusable UVM environment, then reuse *every* layer — RTL, VIP, DV env, and the
register model — inside a larger subsystem.

It is deliberately structured the way a real IP/subsystem team structures work,
so each directory maps to a recognizable deliverable.

```
verification/
├── common/apb_vip/        Reusable APB3 master UVM VIP (agent + RAL adapter + coverage + SVA)
├── ip/apb_timer/          IP #1: a programmable timer — RTL, full UVM env, docs, sim
│   ├── rtl/               apb_timer.sv + bindable SVA
│   ├── dv/                UVM env: RAL, reference-model scoreboard, coverage, IRQ agent, vseqs, tests
│   ├── tb/                tb_top (DUT + interfaces + SVA binds + run_test)
│   ├── sim/               run.f + Makefile + EDA Playground instructions
│   └── docs/              apb_timer_spec.md (the contract)
└── soc/apb_subsystem/     Larger design: interconnect + 2×apb_timer + memory, reusing the above
    ├── rtl/               apb_interconnect + apb_mem_slave + apb_subsystem
    ├── dv/                UVM env reusing the VIP, the timer DV env, and the timer RAL block ×2
    ├── tb/                sim/  docs/
```

## The reuse story (why this layout)

The whole point is to show **vertical and horizontal reuse**, which is what
distinguishes production DV from a one-off testbench:

| Layer            | Built once in…                    | Reused in…                                            |
|------------------|-----------------------------------|-------------------------------------------------------|
| APB VIP agent    | `common/apb_vip`                  | timer env (1×) and subsystem env (1×, drives the fabric)|
| APB RAL adapter  | `common/apb_vip/apb_reg_adapter`  | both register models                                  |
| APB protocol SVA | `common/apb_vip/apb_protocol_checker` | `bind` onto every APB interface instance          |
| Timer RTL        | `ip/apb_timer/rtl`                | instantiated **twice** in the subsystem               |
| Timer RAL block  | `ip/apb_timer/dv/..._reg_block`   | instantiated **twice** in the subsystem's hierarchical reg model |
| Timer DV env     | `ip/apb_timer/dv`                 | instantiated as a **sub-env** per timer in the subsystem env |

## IP #1 — `apb_timer`

A synthesizable APB3 peripheral: a prescaled 32-bit down-counter with a
sticky, level-sensitive interrupt. Full behavioral contract in
[`ip/apb_timer/docs/apb_timer_spec.md`](../ip/apb_timer/docs/apb_timer_spec.md).

```
        APB3 (ADDR_WIDTH=8, DATA_WIDTH=32)          registers
   ┌───────────────────────────────────┐     ┌────────────────────────┐
   │ psel/penable/pwrite/paddr/pwdata   │────▶│ CTRL  (EN/MODE/IRQ_EN)  │
   │ prdata/pready/pslverr              │◀────│ LOAD  VALUE(RO) STATUS  │
   └───────────────────────────────────┘     │ PRESCALE                │──┐
                                              └────────────────────────┘  │
                        prescaler ─▶ down-counter ─▶ timeout ─▶ STATUS.IRQ │
                                                                irq = IRQ_EN & STATUS.IRQ ─▶ irq
```

### Timer UVM environment

```
   apb_timer_env
   ├── apb_agent (ACTIVE)   ── VIP ── drives APB, monitors bus ──▶ analysis
   │        └─ apb_coverage (generic APB dir/addr/slverr)
   ├── timer_irq_agent (PASSIVE)  ── monitors the irq line ──▶ analysis
   ├── RAL: apb_timer_reg_block  ◀── uvm_reg_predictor ◀── apb monitor
   │        (front-door via apb_reg_adapter over the APB agent)
   ├── apb_timer_ref_model  (cycle/tick-accurate shadow of the counter)
   ├── apb_timer_scoreboard (APB reads vs model, IRQ edges vs model, pslverr, one-shot/periodic)
   └── apb_timer_coverage   (CTRL fields, MODE×IRQ_EN, PRESCALE/LOAD bins, timeout, W1C race)
   + bound SVA: apb_protocol_checker (APB compliance) and apb_timer_sva (IRQ semantics)
```

Methodology highlights on display: **RAL** (with an explicit predictor and the
built-in `uvm_reg_hw_reset`/`bit_bash` sequences), a **reference-model
scoreboard**, **functional coverage**, a **virtual-sequence layer**, **config
objects**, **factory-based** construction, and **SVA** both as reusable protocol
checks and design-specific properties.

## The larger design — `apb_subsystem`

```
                     ┌──────────────── apb_subsystem ────────────────┐
   APB3 (12-bit) ───▶│  apb_interconnect  (decode paddr[11:8])       │
                     │      ├─ 0x000 ─▶ apb_timer  (timer0) ─▶ irq0   │
                     │      ├─ 0x100 ─▶ apb_timer  (timer1) ─▶ irq1   │
                     │      ├─ 0x200 ─▶ apb_mem_slave                 │
                     │      └─ else   ─▶ PSLVERR                      │
                     └───────────────────────────────────────────────┘
```

The subsystem env reuses the **same** APB VIP to drive the fabric, wraps each
timer's checking in a reused **sub-env**, and builds a **hierarchical register
model** by instancing the timer RAL block twice (at 0x000 and 0x100) plus a
memory region. A **virtual sequencer** coordinates concurrent, cross-peripheral
scenarios (e.g. both timers armed with different periods, interleaved register
traffic, decode-error injection).

## Running

The RTL and SVA are lint-clean (Verible) locally. The full UVM environments are
compiled and run on commercial simulators (VCS / Questa / Xcelium) — see each
IP's `sim/README.md` for the exact compile order, `Makefile` targets, and
**EDA Playground** setup (which files go in the Design vs Testbench panes, the
UVM version, and the `+UVM_TESTNAME=...` run command).
