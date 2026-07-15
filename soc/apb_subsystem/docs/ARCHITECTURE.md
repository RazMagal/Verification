# `apb_subsystem` — Architecture Overview

A small APB3 subsystem (interconnect + two timers + a memory slave) and the UVM
environment that verifies it. The verification is built almost entirely by
**reuse** of the [`common/apb_vip`](../../../common/apb_vip) VIP and the
[`ip/apb_timer`](../../../ip/apb_timer) IP environment. Diagrams below render on
GitHub (Mermaid).

---

## 1. Hardware architecture (RTL)

```mermaid
flowchart LR
    EXT["APB3 requester<br/>(12-bit addr / 32-bit data)"] -->|"apb_if.slave"| IC

    subgraph DUT["apb_subsystem (DUT top)"]
        direction TB
        IC["apb_interconnect<br/>combinational 1 to 3 fabric<br/>decode paddr[11:8]"]
        IC -->|"page 0x0 (0x000)"| T0["apb_timer<br/>timer0"]
        IC -->|"page 0x1 (0x100)"| T1["apb_timer<br/>timer1"]
        IC -->|"page 0x2 (0x200)"| MEM["apb_mem_slave<br/>64 x 32b RW"]
        IC -.->|"page 0x3..0xF<br/>unmapped"| ERR(("PSLVERR<br/>rdata = 0"))
        T0 --> IRQ0(["irq0"])
        T1 --> IRQ1(["irq1"])
    end
```

### Address map (12-bit APB, decode on `paddr[11:8]`)

| Page (`paddr[11:8]`) | Base    | Slave              | Size          | On error                         |
|----------------------|---------|--------------------|---------------|----------------------------------|
| `0x0`                | `0x000` | `apb_timer` timer0 | 5 registers   | illegal reg offset → slave PSLVERR |
| `0x1`                | `0x100` | `apb_timer` timer1 | 5 registers   | illegal reg offset → slave PSLVERR |
| `0x2`                | `0x200` | `apb_mem_slave`    | 64 × 32-bit   | never errors                     |
| `0x3 … 0xF`          | —       | *(unmapped)*       | —             | fabric PSLVERR, `rdata = 0`      |

### RTL elements

| File | Element | Role |
|------|---------|------|
| `rtl/apb_interconnect.sv` | **Interconnect** | Combinational 1→3 APB fabric: decodes `paddr[11:8]`, drives **per-slave** `psel`/`penable` (each gated by its own select — a broadcast-`penable` bug here was caught by the reused protocol SVA), muxes the response back, and synthesizes PSLVERR for unmapped pages. |
| `rtl/apb_timer.sv` *(from IP)* | **timer0 / timer1** | Two unmodified instances of the `apb_timer` IP: a prescaled down-counter with one-shot/periodic modes and a sticky, maskable interrupt. |
| `rtl/apb_mem_slave.sv` | **Memory slave** | Simple single-cycle 64×32-bit APB RAM; never asserts PSLVERR. |
| `rtl/apb_subsystem.sv` | **DUT top** | Wires the interconnect to both timers + memory over a uniform 12-bit `apb_if`; exposes `irq0`/`irq1`. |

### `apb_timer` register map (each timer page)

| Offset | Register   | Access | Meaning                                   |
|--------|------------|--------|-------------------------------------------|
| `0x00` | `CTRL`     | RW     | `EN[0]`, `MODE[1]` (0=one-shot/1=periodic), `IRQ_EN[2]` |
| `0x04` | `LOAD`     | RW     | Reload / start value for the down-counter |
| `0x08` | `VALUE`    | RO     | Live counter value                        |
| `0x0C` | `STATUS`   | RW1C   | `IRQ[0]` — sticky, write-1-to-clear       |
| `0x10` | `PRESCALE` | RW     | Divisor; one tick = `PRESCALE+1` cycles   |

`irq = IRQ_EN & STATUS.IRQ`. Any other offset in `0x00..0xFF` → illegal → PSLVERR.

---

## 2. Verification environment (UVM)

```mermaid
flowchart TB
    subgraph TB_TOP["tb top — apb_subsystem_tb_top.sv"]
        direction TB
        APB_IF["apb_if (12-bit)<br/>+ 2x timer_irq_if"]
        DUT2["apb_subsystem (DUT)"]
        BINDS["bind: apb_protocol_checker on EVERY apb bus<br/>bind: apb_timer_sva on both timers"]
    end

    subgraph ENV["apb_subsystem_env"]
        direction TB
        TOPAG["m_top_agent — apb_agent (ACTIVE)<br/>drives ALL upstream stimulus"]

        subgraph RAL["Hierarchical RAL"]
            REGB["apb_subsystem_reg_block (root map @ 0x000)<br/>timer0 submap 0x000 · timer1 submap 0x100 · uvm_mem 0x200"]
            PRED["uvm_reg_predictor + apb_reg_adapter"]
        end

        SB["apb_subsystem_scoreboard<br/>fabric decode / PSLVERR + 64-word memory shadow"]
        COV["apb_subsystem_coverage<br/>page x dir x error crosses"]
        VSEQR["apb_subsystem_virtual_sequencer"]

        subgraph REUSE["Reused apb_timer IP env x2 (PASSIVE)"]
            direction LR
            TE0["m_timer_env0<br/>monitor + ref-model + scoreboard + irq agent"]
            TE1["m_timer_env1<br/>monitor + ref-model + scoreboard + irq agent"]
        end
    end

    VSEQR --> TOPAG
    TOPAG -->|"reg / raw APB"| DUT2
    TOPAG -->|"observed beats"| PRED
    TOPAG -->|"observed beats"| SB
    TOPAG -->|"observed beats"| COV
    PRED --> REGB
    DUT2 -. "internal t0_if / irq0" .-> TE0
    DUT2 -. "internal t1_if / irq1" .-> TE1

    classDef reused fill:#1f6f43,stroke:#2ea043,color:#fff;
    classDef newlayer fill:#1f3b6f,stroke:#3b82f6,color:#fff;
    class TE0,TE1,TOPAG,PRED,BINDS reused;
    class REGB,SB,COV,VSEQR,DUT2 newlayer;
```

> **Green = reused unchanged** (VIP agent + adapter/predictor, the two `apb_timer`
> environments, both sets of bound assertions). **Blue = the thin new subsystem
> layer.** All stimulus flows through the *single* active upstream agent; the two
> timer environments run **passive** — monitor + cycle-exact reference model +
> scoreboard + IRQ checker — bound onto the DUT's *internal* timer buses.

### UVM elements

| Component | Reused? | Role |
|-----------|---------|------|
| `m_top_agent` (`apb_agent`, **ACTIVE**) | VIP | The only driver in the system; all register, memory, and illegal-access stimulus goes through it. Its monitor feeds the predictor, scoreboard, and coverage. |
| `m_timer_env0` / `m_timer_env1` (`apb_timer_env`, **PASSIVE**) | IP env | The entire per-timer checker stack (monitor + reference-model scoreboard + IRQ agent) reused unchanged, bound to each timer's internal bus + IRQ line. Each independently proves its timer's counting/IRQ behaviour. |
| `apb_subsystem_reg_block` | new | Hierarchical register model: the `apb_timer_reg_block` reused **twice** as submaps at `0x000`/`0x100`, plus a `uvm_mem` at `0x200`. One predictor on the root map resolves everything by global offset. |
| `uvm_reg_predictor` + `apb_reg_adapter` | VIP | Keep the RAL mirror in sync from passively-monitored bus traffic. |
| `apb_subsystem_scoreboard` | new | Checks the two things the per-timer scoreboards can't see from upstream: **fabric decode / PSLVERR** and **memory contents** (64-word shadow store). |
| `apb_subsystem_coverage` | new | Decode-plan coverage: page × direction × error crosses, with `ignore_bins` for structurally-unreachable combinations (mem-never-errors, unmapped-always-errors). |
| `apb_subsystem_virtual_sequencer` + vseq lib | new | Orchestrates all traffic on the top sequencer via RAL and the reused VIP seqlib. |
| `apb_protocol_checker` (bound) | VIP SVA | AMBA-APB3 protocol assertions bound onto **every** APB bus in the design (upstream + both internal timer buses). |
| `apb_timer_sva` (bound) | IP SVA | Timer interrupt-level / deassert / sticky-STATUS assertions bound onto both timer instances. |

---

## 3. Why this is interesting (reuse story)

- **Block → SoC reuse across three axes:** the same VIP agent, the same IP
  environment (×2, passive), and the same assertions all move up unchanged; only
  a thin composition layer (hierarchical RAL + fabric/memory scoreboard +
  decode coverage) is new.
- **Assertions earned their keep on reuse:** the `apb_timer` protocol checker,
  re-bound onto the interconnect's internal buses, flagged a real fabric bug
  (`penable` broadcast to unselected slaves).
- **One uniform interface width:** because a `virtual apb_if` handle carries its
  parameter widths as part of its *type*, the whole build compiles at 12 bits via
  `+define+APB_ADDR_W=12` (see [`sim/run.f`](../sim/run.f)); the standalone IP
  build stays at the default 8 bits.

See [`REGRESSION.md`](REGRESSION.md) for the test list and how to run it.
