# APB Peripheral IPs & Subsystem — UVM Verification Portfolio

A self-contained demonstration of a modern **SystemVerilog / UVM** design-verification
flow: design APB3 peripherals, verify each with a full-featured UVM environment built on
one shared VIP, then reuse *every* layer — RTL, the APB VIP, the DV environment, and the
register model — to verify a larger subsystem that instantiates a peripheral twice behind
an interconnect. The same VIP powers **three independent IPs** (a timer, a GPIO, and a
silicon-photonic microring tuner), proving the VIP is genuinely reusable rather than
tailored to one block.

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
- **Closed-loop mixed-signal verification** — a `real`-typed behavioural model of a
  photonic microring that the DUT's control loop closes through, checked by a
  property-based scoreboard against the model's internal state rather than by a
  cycle-exact predictor.
- **DPI-C, in both directions** — the ring's optical model also exists as a C model
  (`import "DPI-C"`, plus an `export`ed `sv_ring_event` the C side calls back into), the
  way a photonics team actually ships a device model; a lockstep COMPARE mode qualifies
  it against the SystemVerilog reference, and a `RING_DPI` compile guard keeps the
  default build free of any C dependency.
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
common/dpi/             Optional DPI-C layer: the ring's optical model in C, its SV ABI package, and gcc-only unit tests
ip/apb_timer/           IP #1 — a programmable timer
  rtl/                    apb_timer.sv + timer SVA
  dv/                     UVM env: RAL, reference-model scoreboard, coverage, IRQ agent, vseqs
  tb/  sim/  docs/        tb_top, run scripts, and the register/behavior spec (the contract)
ip/apb_gpio/            IP #2 — general-purpose parallel I/O (reuses the same VIP)
  rtl/                    apb_gpio.sv + gpio SVA
  dv/                     UVM env: RAL, reference-model scoreboard, coverage, pin agent, vseqs
  tb/  sim/  docs/        tb_top, run scripts, and the spec (the contract)
ip/photonic_ring_tuner/ IP #3 — silicon-photonic microring resonance lock (same VIP again)
  rtl/                    photonic_ring_tuner.sv + tuner SVA
  dv/                     UVM env: RAL, closed-loop scoreboard, coverage, vseqs
    optics/                 ring_if + real-number ring/photodiode/ADC model (DV-only)
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

### `photonic_ring_tuner` (IP)
An APB3 **silicon-photonic microring resonance-lock controller**: it drives a thermal
(heater) DAC, reads a monitor photodiode through an ADC, and runs a two-phase loop — a
coarse sweep of the full DAC range to find the resonance, then a fine dither lock that
probes either side of the current code and tracks the peak. `CTRL` (EN), `STEP`
(DITHER/SWEEP), `SETTLE`, `LOCK_CFG` (THRESH/MINPOW), `STATUS` (per-field mixed: RO
`LOCKED`/`ACTIVE`, W1C `RAIL_ERR`/`SWEEP_ERR`), RO `DAC`/`PD`. Lock requires the two
probes to match *and* both to exceed `MINPOW` — the qualifier that stops a **false lock**
on a dark ring, where the curve is flat and a gradient-only test reads "at peak". Full
contract: [`ip/photonic_ring_tuner/docs/photonic_ring_tuner_spec.md`](ip/photonic_ring_tuner/docs/photonic_ring_tuner_spec.md).

**Tests:** `smoke`, `reg` (RAL hw-reset + bit-bash), `error` (pslverr), `lock`,
`settle_short` (must **not** lock), `dark` (SWEEP_ERR, no false lock), `rail` (saturate,
never wrap), `ratio` (fills the settle/tau × outcome cross), `rail_w1c_race` (HW-set-wins
on a sticky flag), `lock_loss` (an established lock is broken and must be reported) — plus
`dpi_equiv` in a `+define+RING_DPI` build (SV vs C model equivalence).

### `apb_subsystem` (SoC-style block)
An APB interconnect decoding `paddr[11:8]` to `timer0` @0x000, `timer1` @0x100, a memory
slave @0x200, and `PSLVERR` otherwise. Its UVM env reuses the VIP to drive the fabric,
nests the timer DV env (passive) once per timer for independent checking, and builds a
**hierarchical register model** by instancing the timer RAL block twice.

**Tests:** `smoke`, `concurrent_timers` (both timers programmed differently and run
together, each interrupt checked independently), `mem`, `decode_error`, `rand`.

## What the photonics IP adds

The timer and the GPIO are both *open-loop* digital blocks: stimulus goes in, a
cycle-exact reference model predicts what should come out, and the scoreboard compares.
`photonic_ring_tuner` cannot be verified that way, and that is the point of having it.

- **The loop is closed through continuous physics.** The DUT's `adc_code` input is a
  function of its own `dac_code` output, so the DV environment supplies a **real-number
  behavioural model** of the ring — first-order thermal lag, Lorentzian lineshape,
  photodiode and ADC — and the control loop closes through it. Optics cannot be simulated
  by an event-driven digital simulator; verifying the electronic control plane against a
  behavioural model of the optical device is how photonic ICs are actually signed off.
- **There is no stimulus sequence to write.** Nothing can be pre-computed, because every
  sample depends on what the DUT just did. The stimulus is the *physics* — where the
  resonance sits, how sharp it is, how slow the heater is, whether there is light at all
  — randomized per test as a configuration object, after which the ring drives itself.
- **The checking moves from equality to properties.** A bit-exact predictor would have to
  re-implement the ring, the photodiode and the ADC rounding, and would then only be
  testing itself. The scoreboard instead checks properties of the closed loop —
  acquisition inside a deadline *derived from the programmed registers*, accuracy against
  the model's internal detuning, DAC stability while locked, no false lock on a dark ring,
  saturation without wraparound at the rail. Probing a behavioural model's internal state
  to make the accuracy check possible at all is standard mixed-signal DV practice.
- **The headline coverage item is a physical ratio, not a register field.** The thermal
  time constant is deliberately scaled down so a lock can finish in simulation, which is
  sound because the controller can only ever observe the **ratio** of its programmed
  settle time to that time constant, never absolute time. Crossing that ratio against the
  lock outcome targets the archetypal photonic control bug: sample the photodiode before
  the ring has thermally settled and the loop walks the wrong way and never acquires.

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
# the photonic tuner (its optical model is DV-only and non-synthesizable)
make -C ip/photonic_ring_tuner/sim questa TEST=photonic_ring_tuner_lock_test
# the subsystem (note the width define is baked into its run.f)
make -C soc/apb_subsystem/sim xrun  TEST=apb_subsystem_concurrent_timers_test
```

The subsystem build compiles the VIP with `+define+APB_ADDR_W=12` so every APB interface
and the VIP's virtual-interface handles are a uniform 12-bit width.

**RTL + SVA — local lint.** The synthesizable RTL and the plain-SVA checkers are kept
lint-clean with [Verible](https://github.com/chipsalliance/verible)
(`verible-verilog-syntax` / `verible-verilog-lint`), so structural mistakes are caught
before anything reaches the simulator.
