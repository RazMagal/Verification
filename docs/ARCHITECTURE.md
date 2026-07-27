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
├── ip/apb_gpio/           IP #2: general-purpose parallel I/O — reuses the SAME VIP
│   ├── rtl/               apb_gpio.sv + bindable SVA
│   ├── dv/                UVM env: RAL, reference-model scoreboard, coverage, pin agent, vseqs, tests
│   └── tb/  sim/  docs/   tb_top, run scripts, apb_gpio_spec.md (the contract)
├── ip/photonic_ring_tuner/ IP #3: microring resonance lock — the SAME VIP, closed-loop DV
│   ├── rtl/               photonic_ring_tuner.sv + bindable SVA
│   ├── dv/                UVM env: RAL, closed-loop property scoreboard, coverage, vseqs, tests
│   │   └── optics/        ring_if + real-number ring/photodiode/ADC model (DV-only)
│   └── tb/  sim/  docs/   tb_top, run scripts, photonic_ring_tuner_spec.md (the contract)
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
| APB VIP agent    | `common/apb_vip`                  | timer env, **gpio env**, **tuner env**, and subsystem env (drives the fabric)|
| APB RAL adapter  | `common/apb_vip/apb_reg_adapter`  | all four register models (timer, gpio, tuner, subsystem) |
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

## IP #2 — `apb_gpio`

A second, independent peripheral built to prove the VIP is genuinely reusable, not
tailored to the timer. A general-purpose parallel I/O block: per-pin direction, a
2-flop-synchronized input path, and per-pin rising-edge interrupts. Full contract in
[`ip/apb_gpio/docs/apb_gpio_spec.md`](../ip/apb_gpio/docs/apb_gpio_spec.md).

```
        APB3 (ADDR_WIDTH=8, DATA_WIDTH=32=NPINS)      registers
   ┌───────────────────────────────────┐     ┌────────────────────────┐
   │ psel/penable/pwrite/paddr/pwdata   │────▶│ DATA_OUT   DIR          │──▶ gpio_out / gpio_oe
   │ prdata/pready/pslverr              │◀────│ DATA_IN(RO) INT_EN      │
   └───────────────────────────────────┘     │ INT_STATUS (W1C)        │
                                              └────────────────────────┘
     gpio_in ─▶ [2-FF sync] ─▶ DATA_IN ─▶ rising-edge ─▶ INT_STATUS (sticky)
                                          irq = |(INT_STATUS & INT_EN) ─▶ irq
```

The `apb_gpio` UVM env mirrors the timer's (RAL + reference-model scoreboard +
coverage + bound SVA) but adds a **second, *active* pin agent** that drives `gpio_in`
and observes `gpio_out`/`gpio_oe`/`irq`, and a reference model that shadows the input
synchronizer so `DATA_IN` readback and each interrupt set are checked **cycle-exactly**.
It reuses the APB agent, adapter, coverage, and protocol SVA from `common/apb_vip`
unchanged — the same reuse the subsystem relies on, exercised by a different design.

## IP #3 — `photonic_ring_tuner`

A third peripheral on the same VIP, added because it is verified *differently*, not
merely shaped differently. A silicon-photonic microring resonance-lock controller: it
drives a thermal (heater) DAC, reads a monitor photodiode through an ADC, and runs a
two-phase loop that parks the ring's optical resonance on the laser line and holds it
there. Full contract in
[`ip/photonic_ring_tuner/docs/photonic_ring_tuner_spec.md`](../ip/photonic_ring_tuner/docs/photonic_ring_tuner_spec.md).

```
        APB3 (ADDR_WIDTH=8, DATA_WIDTH=32)          registers
   ┌───────────────────────────────────┐     ┌────────────────────────┐
   │ psel/penable/pwrite/paddr/pwdata   │────▶│ CTRL(EN)  STEP  SETTLE  │
   │ prdata/pready/pslverr              │◀────│ LOCK_CFG  STATUS(mixed) │
   └───────────────────────────────────┘     │ DAC(RO)   PD(RO)        │
                                              └────────────────────────┘
   coarse sweep (ramp the DAC, keep the brightest code) ─▶ fine dither lock
        (probe ±DITHER, move toward the brighter probe; at_peak needs
         |p_hi-p_lo| <= THRESH AND both probes >= MINPOW)
        LOCK_N consecutive at-peak iterations ─▶ locked        ──▶ dac_code / locked
```

The `MINPOW` term is what makes the lock rule safe: far off resonance the transmission
curve is flat, so both probes read ≈ 0 and are *equal* — a gradient-only rule declares a
confident **false lock** on a dark ring.

### The closed loop (why this env is not like the other two)

```
   dac_code ─▶ ring_model : thermal lag ─▶ Lorentzian lineshape ─▶ photodiode/ADC
        ▲                                                                │
        └──────────── DUT control loop ◀──────────── adc_code ◀───────────┘
```

Optics are continuous physics and cannot be simulated by an event-driven digital
simulator, so the DV environment supplies a **real-number (`real`-typed) behavioural
model** of the ring and the loop closes through it — the standard way photonic ICs are
verified. The DUT's input is therefore a function of its own output, which changes the
verification strategy in three places:

- **Stimulus.** Nothing can be pre-computed, so there is no data sequence and no optical
  *agent*. `ring_cfg` randomizes the *physics* (resonance position, linewidth, thermal
  time constant, peak power, noise, laser on/off) into one of five constrained regimes,
  applies it to `ring_if` before reset is released, and the ring then drives itself.
  Each regime violates exactly one precondition of acquisition, so the negative tests
  are self-checking rather than hopeful.
- **Checking.** No cycle-exact reference model: a bit-exact predictor would have to
  re-implement the ring, the photodiode and the ADC rounding, and would then only be
  testing itself. The scoreboard checks **properties of the closed loop** — acquisition
  inside a deadline derived from the programmed `SWEEP`/`SETTLE`/`DITHER`, accuracy
  against the model's internal `detune_code`, DAC stability while locked, no false lock
  on a dark ring, and saturation-without-wrap at the rail. Exporting `detune_code` is
  what makes the accuracy check possible at all — "the loop locked to the *actual*
  resonance" is unobservable from the DUT's pins.
- **Time.** A real ring's thermal time constant is microseconds to milliseconds and
  would take 10⁵–10⁶ clocks to simulate, so `tau_cycles` is deliberately scaled down.
  That is sound because the controller can only ever observe the **ratio** of its
  programmed settle time to `tau`, never absolute time — so the tests and the coverage
  plan sweep the ratio.

### Tuner UVM environment

```
   photonic_ring_tuner_env
   ├── apb_agent (ACTIVE)   ── VIP ── drives APB, monitors bus ──▶ analysis
   │        └─ apb_coverage (generic APB dir/addr/slverr)
   ├── RAL: photonic_ring_tuner_reg_block ◀── uvm_reg_predictor ◀── apb monitor
   │        (STATUS is per-FIELD mixed RO/W1C; DAC/PD are RO + volatile)
   ├── photonic_ring_tuner_scoreboard (the five closed-loop properties above,
   │        sampling ring_if once per posedge through a preponed clocking block)
   └── photonic_ring_tuner_coverage   (register programming + the acquisition result)
   (no optical agent — ring_cfg CONFIGURES ring_if and the physics is the stimulus)
   + tb-side: ring_model (real-number optics, DV-only, NON-synthesizable)
   + bound SVA: apb_protocol_checker (APB compliance) and photonic_ring_tuner_sva
     (locked/port equality, no DAC wraparound, no lock without power, sticky error
      flags, probe polarity, SETTLE honoured)
```

The headline coverage item is the **settle/tau ratio crossed with the lock outcome**: it
is the axis the archetypal photonic control bug lives on — sample the photodiode before
the ring has thermally settled and the loop walks the wrong way and never acquires. The
cross is left complete on purpose, because the `(ratio < 1, locked)` cell is exactly the
one whose appearance would be a finding.

v1.0 models a single resonance. Free-spectral-range / wrong-peak lock, thermal crosstalk,
laser drift and PID control are explicitly out of scope (spec §8), so the boundary is a
design decision rather than an oversight.

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
compiled and run on commercial simulators (Aldec Riviera-PRO / VCS / Questa /
Xcelium; Riviera-PRO needs no EDA Playground account validation) — see each
IP's `sim/README.md` for the exact compile order, `Makefile` targets, and
**EDA Playground** setup (which files go in the Design vs Testbench panes, the
UVM version, and the `+UVM_TESTNAME=...` run command).
