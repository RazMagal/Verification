# `apb_timer` — Specification (v1.0)

A small, synthesizable APB3 peripheral: a programmable down-counter with a
prescaler and a level-sensitive interrupt output. Designed to be rich enough to
exercise a full UVM environment (RAL, reference-model scoreboard, functional
coverage, a second monitor agent on the IRQ line, and SVA) while staying
bounded and fast to simulate.

This document is the **single source of truth**. RTL and DV must agree on every
name, offset, bit position, and timing statement here.

---

## 1. Interface

APB3 slave, using the shared VIP interface `apb_if` (`common/apb_vip/apb_if.sv`).

Parameters (for the standalone IP):
- `ADDR_WIDTH = 8`  (byte address; only bits `[7:0]` used, offsets are word-aligned)
- `DATA_WIDTH = 32`

Ports (in addition to the `apb_if` bundle):
- `input  logic        clk`     — from `apb_if.clk`
- `input  logic        rst_n`   — from `apb_if.rst_n` (async assert, sync deassert; active-low)
- `output logic        irq`     — level-sensitive interrupt (separate `timer_if`)

APB3 signals (driven/observed on `apb_if`): `psel, penable, pwrite, paddr,
pwdata, prdata, pready, pslverr`.

### APB timing contract
- Standard APB3 two-phase transfer: **SETUP** (`psel=1, penable=0`) then
  **ACCESS** (`psel=1, penable=1`).
- The slave completes every legal transfer in the ACCESS cycle: it asserts
  `pready=1` for exactly one cycle (no wait states in v1.0 — a `PREADY` wait
  hook may be added later; DV must not assume >0 wait states but must tolerate
  the driver waiting on `pready`).
- `prdata` is valid in the ACCESS cycle when `pready=1` for a read.
- `pslverr` is asserted (with `pready=1`) in the ACCESS cycle for an illegal
  access (see §4). On `pslverr`, a read returns `prdata = 0`.

---

## 2. Register map

Word-aligned, 32-bit registers. Byte offset = `paddr` (word index = `paddr>>2`).

| Offset | Name       | Access | Reset      | Description                              |
|-------:|------------|--------|-----------:|------------------------------------------|
| 0x00   | `CTRL`     | RW     | 0x0000_0000| Control                                  |
| 0x04   | `LOAD`     | RW     | 0x0000_0000| Reload / start value for the down-counter|
| 0x08   | `VALUE`    | RO     | 0x0000_0000| Current counter value (live)             |
| 0x0C   | `STATUS`   | RW1C   | 0x0000_0000| Interrupt status                         |
| 0x10   | `PRESCALE` | RW     | 0x0000_0000| Prescaler divisor                        |

Any other offset in `[0x00 .. 0xFF]` → **illegal access** → `pslverr` (see §4).

### 2.1 `CTRL` (0x00, RW)
| Bits   | Field     | Access | Description                                                |
|-------:|-----------|--------|------------------------------------------------------------|
| 0      | `EN`      | RW     | 1 = counter enabled (counting), 0 = halted                 |
| 1      | `MODE`    | RW     | 0 = one-shot, 1 = periodic                                 |
| 2      | `IRQ_EN`  | RW     | 1 = allow `irq` output to be driven by `STATUS.IRQ`        |
| 31:3   | reserved  | RO     | reads 0, writes ignored                                    |

### 2.2 `LOAD` (0x04, RW)
- `[31:0]` reload value. See §3 for when the counter (re)loads from `LOAD`.

### 2.3 `VALUE` (0x08, RO)
- `[31:0]` current live value of the down-counter. Writes are ignored (no
  `pslverr` — RO writes complete normally and are dropped).

### 2.4 `STATUS` (0x0C, RW1C)
| Bits   | Field     | Access | Description                                                    |
|-------:|-----------|--------|---------------------------------------------------------------|
| 0      | `IRQ`     | RW1C   | Sticky interrupt flag; set by HW on timeout, cleared by writing 1 |
| 31:1   | reserved  | RO     | reads 0                                                       |

Write-one-to-clear: writing `1` to bit 0 clears it; writing `0` leaves it.
If HW sets and SW clears in the same cycle, **HW set wins** (flag stays set).

### 2.5 `PRESCALE` (0x10, RW)
- `[7:0]` prescaler divisor `N`. The down-counter decrements once every `N+1`
  `clk` cycles while enabled (N=0 → every cycle). `[31:8]` reserved, read 0.

---

## 3. Functional behavior

Let `cnt` be the internal down-counter (reads back on `VALUE`), `psc` the
internal prescale counter.

**Load semantics.** `cnt` is (re)loaded from `LOAD` when:
- `CTRL.EN` transitions `0 → 1` (start), **or**
- a timeout reload occurs in periodic mode (see below).
- `psc` is reset to 0 on the same events.
- Writing `LOAD` while running does **not** immediately reload `cnt`; it takes
  effect at the next start or periodic reload. (Simple, race-free semantics.)

**Counting.** While `CTRL.EN==1`:
- Each `clk`, increment `psc`. When `psc == PRESCALE` (i.e. after `N+1` cycles),
  reset `psc=0` and decrement `cnt` by 1 (a "tick").
- **Timeout** occurs on the tick that takes `cnt` from `1 → 0` (i.e. `cnt`
  becomes 0). On timeout:
  - `STATUS.IRQ` is set to 1 (sticky).
  - If `CTRL.MODE==1` (periodic): reload `cnt` from `LOAD`, reset `psc=0`,
    continue counting.
  - If `CTRL.MODE==0` (one-shot): `CTRL.EN` is auto-cleared to 0, `cnt` stays 0,
    counting stops.

**Special case `LOAD==0` at start:** starting with `LOAD==0` causes an immediate
timeout on the first enabled tick boundary (`cnt` loads 0, the first tick fires
timeout). Periodic mode with `LOAD==0` therefore fires every `N+1` cycles. DV
should cover but need not stress this; RTL must not deadlock.

**Interrupt output.** `irq = CTRL.IRQ_EN & STATUS.IRQ` — purely combinational
from the two live register bits (level-sensitive, deasserts the cycle after SW
clears `STATUS.IRQ` or clears `IRQ_EN`).

**Reset.** Async assert, sync deassert, active-low `rst_n`. All registers,
`cnt`, `psc`, and `irq` reset to 0.

---

## 4. Error / illegal access (`pslverr`)

`pslverr` is asserted (with `pready`) in the ACCESS phase when:
- `paddr` (byte offset) is **not** one of `0x00,0x04,0x08,0x0C,0x10`
  (i.e. unmapped, including non-word-aligned addresses).

On `pslverr`:
- Writes have no side effect (register state unchanged).
- Reads return `prdata = 0`.

Legal writes to RO fields / RO register (`VALUE`) do **not** raise `pslverr`;
the write simply has no effect. (Keeps the RAL `VALUE` reg as plain RO.)

---

## 5. DV expectations (for the UVM env)

- **RAL:** `apb_timer_reg_block` mirrors CTRL/LOAD/VALUE/STATUS/PRESCALE with
  correct access policies (RW, RW, RO, W1C, RW). Front-door via APB reg adapter;
  `VALUE` and `STATUS.IRQ` are HW-updated → predictor/`uvm_reg` mirror handled
  via explicit prediction from the scoreboard reference model.
- **Reference model / scoreboard:** a cycle-accurate (tick-accurate) model of
  `cnt`/`psc`/timeout/IRQ that predicts `VALUE` reads, `STATUS.IRQ`, and `irq`.
- **IRQ agent:** a passive monitor on the `irq` line producing transactions on
  edges; scoreboard checks predicted vs. observed IRQ assert/deassert.
- **Coverage:** CTRL fields (EN/MODE/IRQ_EN), MODE×IRQ_EN cross, PRESCALE bins
  (0, small, max), LOAD bins (0, 1, small, large), timeout events, one-shot vs
  periodic reload, pslverr seen, W1C-while-HW-set race hit.
- **Sequences:** smoke (reg reset check), one-shot timeout, periodic N-timeouts,
  prescaler>0, W1C clear, illegal-address (pslverr), and randomized register
  stress.

---

## 6. Subsystem reuse (see `soc/apb_subsystem`)

`apb_timer` is instantiated twice inside `apb_subsystem` behind an
`apb_interconnect` (address decoder), alongside a memory slave. The DV reuses
the APB VIP agent, the `apb_timer` DV env (as a sub-env per instance), and the
`apb_timer_reg_block` (instantiated twice in a hierarchical `uvm_reg_block`).
Address map there:

| Slave     | Base   | Range          |
|-----------|--------|----------------|
| `timer0`  | 0x000  | 0x000 .. 0x0FF |
| `timer1`  | 0x100  | 0x100 .. 0x1FF |
| `mem`     | 0x200  | 0x200 .. 0x2FF |
| (default) | —      | → `pslverr`    |

Subsystem APB uses `ADDR_WIDTH = 12`. Decode on `paddr[11:8]`.
