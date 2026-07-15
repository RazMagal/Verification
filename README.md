# APB Peripheral IPs & Subsystem — UVM Verification Portfolio

A self-contained demonstration of a modern **SystemVerilog / UVM** design-verification
flow: design APB3 peripherals, verify each with a full-featured UVM environment built on
one shared VIP, then reuse *every* layer — RTL, the APB VIP, the DV environment, and the
register model — to verify a larger subsystem that instantiates a peripheral twice behind
an interconnect. The same VIP powers **two independent IPs** (a timer and a GPIO),
proving the VIP is genuinely reusable rather than tailored to one block.

> *Built on the EDA Playground workflow (commercial simulators for UVM), version-controlled
> here so the engineering — and its history — is visible.*

---

## What this repository demonstrates

- **A reusable APB3 master VIP** — driver, monitor, sequencer, agent, config object,
  sequence library, functional-coverage collector, and a **`uvm_reg_adapter`** so the same
  agent carries RAL traffic.
- **RAL (register abstraction layer)** — a `uvm_reg_block` with correct access policies
  (RW / RO / **W1C** / reserved), an explicit **`uvm_reg_predictor`**, front-door access
  through the APB adapter, and the built-in **`uvm_reg_hw_reset` / `uvm_reg_bit_bash`**
  sequences.
- **A cycle-exact reference-model scoreboard** — an independent shadow of the timer that
  predicts every register read, the live counter, and each interrupt edge, matched
  in-order through analysis FIFOs with a zero-activity guard.
- **Functional coverage** — control fields, mode × irq_en crosses, prescaler/load bins,
  timeout events, error responses, and the W1C-vs-HW-set race.
- **A second (interrupt) agent**, **virtual sequences**, **config objects**, **factory**
  construction, and **SVA** — both a reusable APB-protocol checker and timer-specific
  properties, `bind`-ed onto the interfaces and the DUT.
- **Vertical + horizontal reuse** — the timer's VIP, DV env, and RAL block are all reused
  to verify the subsystem with only a thin new layer of code.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for block diagrams and the full strategy.

---

## Repository layout

```
common/apb_vip/         Reusable APB3 master UVM VIP + bindable APB protocol SVA
ip/apb_timer/           IP #1 — a programmable timer
  rtl/                    apb_timer.sv + timer SVA
  dv/                     UVM env: RAL, reference-model scoreboard, coverage, IRQ agent, vseqs
  tb/  sim/  docs/        tb_top, run scripts, and the register/behavior spec (the contract)
ip/apb_gpio/            IP #2 — general-purpose parallel I/O (reuses the same VIP)
  rtl/                    apb_gpio.sv + gpio SVA
  dv/                     UVM env: RAL, reference-model scoreboard, coverage, pin agent, vseqs
  tb/  sim/  docs/        tb_top, run scripts, and the spec (the contract)
soc/apb_subsystem/      Larger design — interconnect + 2×apb_timer + memory, reusing the above
  rtl/ dv/ tb/ sim/ docs/
docs/ARCHITECTURE.md    Architecture & verification-strategy overview
```

## The designs

### `apb_timer` (IP)
An APB3 programmable down-counter: `CTRL` (EN / MODE / IRQ_EN), `LOAD`, `VALUE` (RO live
count), `STATUS` (W1C interrupt flag), `PRESCALE`; a prescaled counter that runs one-shot
or periodic; a level interrupt `irq = IRQ_EN & STATUS.IRQ`; and `PSLVERR` on unmapped
access. Full contract: [`ip/apb_timer/docs/apb_timer_spec.md`](ip/apb_timer/docs/apb_timer_spec.md).

**Tests:** `smoke`, `oneshot`, `periodic`, `prescale`, `w1c`, `irq_mask`, `error` (pslverr),
`reg` (RAL hw-reset + bit-bash), `rand`.

### `apb_gpio` (IP)
An APB3 general-purpose I/O block: `DATA_OUT`, `DATA_IN` (RO, 2-flop synchronized),
`DIR` (per-pin output enable), `INT_STATUS` (W1C rising-edge flags), `INT_EN`; a level
interrupt `irq = |(INT_STATUS & INT_EN)`; and `PSLVERR` on unmapped access. It reuses the
**same** APB VIP as the timer but adds a new surface — a bidirectional-style pin interface,
an input synchronizer, and edge-triggered interrupts — verified by a second, *active* pin
agent and a cycle-exact reference model that mirrors the synchronizer. Full contract:
[`ip/apb_gpio/docs/apb_gpio_spec.md`](ip/apb_gpio/docs/apb_gpio_spec.md).

**Tests:** `smoke`, `output_drive`, `input_capture`, `interrupt`, `w1c`, `error` (pslverr),
`reg` (RAL hw-reset + bit-bash), `rand`.

### `apb_subsystem` (SoC-style block)
An APB interconnect decoding `paddr[11:8]` to `timer0` @0x000, `timer1` @0x100, a memory
slave @0x200, and `PSLVERR` otherwise. Its UVM env reuses the VIP to drive the fabric,
nests the timer DV env (passive) once per timer for independent checking, and builds a
**hierarchical register model** by instancing the timer RAL block twice.

**Tests:** `smoke`, `concurrent_timers` (both timers programmed differently and run
together, each interrupt checked independently), `mem`, `decode_error`, `rand`.

## A verification find worth noting

Binding the **reused** APB-protocol SVA onto the subsystem's *internal* buses immediately
caught a real fabric bug: the interconnect drove `penable` to unselected slaves
(`penable |-> psel` violation). Functionally harmless, but a genuine protocol
nonconformance — and exactly the kind of issue a reused VIP checker surfaces that a
hand-written per-block testbench would miss. Fixed in
[`soc/apb_subsystem/rtl/apb_interconnect.sv`](soc/apb_subsystem/rtl/apb_interconnect.sv).

## Running it

**UVM (full environments) — EDA Playground or any commercial simulator.** Each `sim/`
directory has a `run.f` compile-order filelist, a `Makefile` with `questa` / `vcs` / `xrun`
targets and a multi-seed `regress`, and a `README.md` describing exactly which files go in
the Design vs. Testbench panes on EDA Playground and the `+UVM_TESTNAME=...` invocation.

```sh
# e.g. the standalone timer, on Questa
make -C ip/apb_timer/sim   questa TEST=apb_timer_oneshot_test
# the subsystem (note the width define is baked into its run.f)
make -C soc/apb_subsystem/sim xrun  TEST=apb_subsystem_concurrent_timers_test
```

The subsystem build compiles the VIP with `+define+APB_ADDR_W=12` so every APB interface
and the VIP's virtual-interface handles are a uniform 12-bit width.

**RTL + SVA — local lint.** The synthesizable RTL and the plain-SVA checkers are kept
lint-clean with [Verible](https://github.com/chipsalliance/verible)
(`verible-verilog-syntax` / `verible-verilog-lint`), so structural mistakes are caught
before anything reaches the simulator.
