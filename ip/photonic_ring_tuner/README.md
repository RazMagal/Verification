# `photonic_ring_tuner` — silicon-photonic microring resonance lock (RTL + UVM DV)

An APB3 peripheral that parks a silicon-photonic microring on its laser line and
holds it there: it drives a thermal (heater) DAC, reads a monitor photodiode
through an ADC, and closes a digital control loop between the two. A third IP
that **reuses the same APB VIP** as `apb_timer` and `apb_gpio`, but exercises a
surface neither of them has — a **closed mixed-signal loop**, in which the DUT's
input is a continuous-valued function of its own output.

- **Spec (the contract):** [`docs/photonic_ring_tuner_spec.md`](docs/photonic_ring_tuner_spec.md) —
  port list, register map, FSM encoding, the internal signal names the bound SVA
  relies on, and the normative real-number optical model.
- **Regression list:** [`docs/REGRESSION.md`](docs/REGRESSION.md) — the 11 tests
  (10 in the default suite, plus a DPI-C model-equivalence test that only exists
  in a `+define+RING_DPI` build), what each one proves, and how to run them.

## Why a photonic block is a verification problem at all

A microring resonator only passes light at wavelengths matching its resonance,
and that resonance moves with temperature and with process variation — tens of
linewidths of drift is normal, so a fabricated ring is essentially *never*
aligned to its laser at power-up. Every silicon-photonic link therefore ships a
**digital** control loop that heats the ring until its resonance sits on the
laser line. That loop is the DUT.

The optics themselves are continuous physics and **cannot be simulated by an
event-driven digital simulator**. The DV environment therefore supplies a
**real-number (`real`-typed) behavioural model** of the ring — first-order
thermal lag, Lorentzian lineshape, photodiode and ADC — and the control loop
closes through it. This is the standard way photonic ICs are verified: the
electronic control plane is verified against a behavioural model of the optical
device.

Two consequences shape the whole environment:

- **There is no stimulus sequence to write.** `adc_code` is whatever the ring
  returns for the `dac_code` the DUT just drove, so the interesting stimulus is
  the *physics* — where the resonance sits, how sharp it is, how slow the heater
  is, whether there is any light at all. That is randomized per test through a
  `ring_cfg` object; the sequences program the loop over the RAL and then wait
  for a physical outcome.
- **Time is scaled** (spec §7.3). A real ring's thermal time constant is
  microseconds to milliseconds; at 100 MHz a faithful `tau` would be 10⁵–10⁶
  clocks and one acquisition would never finish in simulation, so `tau_cycles`
  is deliberately scaled down to tens of cycles. That is sound because the
  controller cannot observe `tau` in absolute time — it only ever observes the
  **ratio `SETTLE / tau_cycles`**, i.e. whether it waited long enough for the
  ring to reach its commanded temperature before sampling. Preserving the ratio
  preserves every bug the loop can have, which is why the tests and the coverage
  plan sweep the *ratio* rather than a fixed `tau`.

## Register map

Byte offsets in `[0x00 .. 0xFF]`; any other offset raises `PSLVERR`. Full
field-level contract in [the spec](docs/photonic_ring_tuner_spec.md#2-register-map-byte-offsets-in-0x00--0xff).

| Offset | Name | Access | Reset | Summary |
|--------|------|--------|-------|---------|
| `0x00` | `CTRL` | RW | `0` | `[0] EN` — a **rising edge** starts a fresh acquisition |
| `0x04` | `STEP` | RW | `0x0000_2004` | `[7:0] DITHER`, `[15:8] SWEEP` — step sizes in DAC LSBs (0 clamps to 1 in HW) |
| `0x08` | `SETTLE` | RW | `0x0000_0020` | clocks to wait after moving the DAC before sampling the ADC |
| `0x0C` | `LOCK_CFG` | RW | `{2**(ADC_WIDTH-4), 16'h0008}`<br>= `0x0100_0008` at the default `ADC_WIDTH = 12` | `[15:0] THRESH`, `[31:16] MINPOW` — lock criteria in ADC LSBs. `MINPOW` resets to ADC **full-scale/16**, `THRESH` to an **absolute** 8 LSBs — see below |
| `0x10` | `STATUS` | mixed | `0` | `[0] LOCKED` RO, `[1] RAIL_ERR` W1C, `[2] SWEEP_ERR` W1C, `[3] ACTIVE` RO |
| `0x14` | `DAC` | RO | `0` | current centre code `dac_q` |
| `0x18` | `PD` | RO | `0` | most recent ADC sample `pd_q` |

`STATUS` mixes access types **within one register** — live read-only hardware
state next to sticky W1C error flags — so the RAL exercises per-*field* access
policies rather than per-register ones, as `STEP` and `LOCK_CFG` do for packed
RW fields.

## Two-phase architecture: coarse sweep, then dither lock

The controller runs in two phases, as real tuners do:

1. **Coarse sweep** (`S_SWEEP_WAIT` / `S_SWEEP_SAMP`) — ramp the heater DAC from
   0 across its full range in `SWEEP` steps, waiting `SETTLE` clocks at each
   point, and record the code that produced the most light. Gradient descent
   cannot start cold: far from resonance the photodiode signal is flat and the
   gradient is buried in noise. If the best sample never reaches `MINPOW` the
   sweep sets `SWEEP_ERR` and parks in `S_IDLE` until software re-arms `EN` —
   no resonance exists in the tuning range (laser off, fibre unplugged, dead
   photodiode, or `MINPOW` above the achievable peak).
2. **Fine dither lock** (`S_HI_*` / `S_LO_*` / `S_UPDATE`) — probe one `DITHER`
   step above and one below the current code, move toward the brighter probe,
   and declare lock only when the two probes are equal to within `THRESH`
   **and** both exceed `MINPOW`, for `LOCK_N` consecutive iterations. Probe
   drive is clamped at the rails, never wrapped; a move that saturates sets
   `RAIL_ERR`.

The **`MINPOW` qualifier is what prevents a false lock**, and it is the first
thing this block has to be proven not to do. Far off resonance the transmission
curve is flat, so both dither probes read ≈ 0 and are equal — a lock rule based
on the gradient alone confidently declares "at peak" on a completely dark ring.
Requiring both probes to exceed `MINPOW` rejects that.

Which is why `MINPOW`'s **reset scales with `ADC_WIDTH`** (`full-scale/16 =
2**(ADC_WIDTH-4)`, exactly `0x100` at the default 12 bits) while `THRESH` stays
absolute: `MINPOW` is a fraction of the expected peak — narrowing the ADC changes
the quantization, not the optics — whereas `THRESH` separates a real gradient from
a ~0.5-LSB quantization noise floor. A hardcoded `0x100` fails in both directions,
and the one to fear is the **permissive** one: at `ADC_WIDTH = 16` it would be
0.39 % of full scale, so a nearly dark ring passes the only check that exists to
reject it and the block declares a confident false lock. (At `ADC_WIDTH = 8` it
fails the *loud* way instead — `0x100` is above a full scale of `255`, so nothing
can ever lock.) Full rationale in
[spec §2](docs/photonic_ring_tuner_spec.md#2-register-map-byte-offsets-in-0x00--0xff).

`locked` is a live status, not a sticky flag: it deasserts as soon as a single
iteration is not at peak.

## RTL (`rtl/`)
| File | Role |
|------|------|
| `photonic_ring_tuner.sv` | The DUT — APB3 slave, the eight-state sweep/dither FSM, `DAC`/`PD` observability, sticky `RAIL_ERR`/`SWEEP_ERR` (HW-set-wins over W1C), clamped probe drive, `PSLVERR` on unmapped access |
| `photonic_ring_tuner_sva.sv` | Bindable tuner-specific SVA (`locked` vs `locked_q`, no DAC wraparound, the two-part no-lock-without-power guard, sticky error flags, probe polarity, `SETTLE` honoured) |

The reusable APB protocol checker lives in [`common/apb_vip/apb_protocol_checker.sv`](../../common/apb_vip/apb_protocol_checker.sv).

## DV (`dv/`)
| File | Role |
|------|------|
| `optics/ring_if.sv` | Optical interface: the DUT-facing loop (`dac_code`/`adc_code`/`locked`), the `real` physical configuration, and the `detune_code`/`temp_code` observables, with a preponed monitor clocking block |
| `optics/ring_model.sv` | The real-number ring model (spec §7.2): thermal lag → Lorentzian → photodiode → ADC. **Non-synthesizable by design**, DV-only. Also hosts the optional DPI-C backend switch (below) |
| `photonic_ring_tuner_reg_block.svh` | RAL model (`CTRL`/`STEP`/`SETTLE`/`LOCK_CFG` RW, `STATUS` per-field mixed, `DAC`/`PD` RO+volatile) |
| `photonic_ring_tuner_env_cfg.svh` | Env config plus `ring_cfg` — the randomizable *physics*, with one constraint regime per test outcome, and the single acquisition-deadline formula |
| `photonic_ring_tuner_scoreboard.svh` | The five spec-§7.5 closed-loop checks: acquisition inside a derived deadline, accuracy against the model's `detune_code`, stability of `dac_code` while locked, no false lock on a dark ring, saturation-without-wrap at the rail |
| `photonic_ring_tuner_coverage.svh` | Functional coverage (spec §7.6), built around the settle/tau × lock-outcome cross |
| `photonic_ring_tuner_env.svh` | Env assembly: reused APB agent, explicit `uvm_reg_predictor`, scoreboard, coverage |
| `seq/photonic_ring_tuner_vseq_lib.svh` | Virtual sequences (smoke / reg / lock / settle_short / dark / rail / error / ratio / rail_w1c_race / lock_loss / dpi_equiv) |
| `test/photonic_ring_tuner_test_lib.svh` | Test library — a derived test overrides the ring regime, the expected outcome, and the vseq |
| `photonic_ring_tuner_pkg.sv` | Compilation package (imports the reused `apb_vip_pkg`) |

The APB agent, sequencer, adapter, coverage and sequence library are **reused**
from [`common/apb_vip`](../../common/apb_vip), unchanged.

Two structural choices are worth calling out:

- **There is no optical agent.** The ring is not driven with transactions — it
  is *configured* and then drives itself, because the DUT's `adc_code` input is
  a function of its own `dac_code` output through `ring_model`.
- **There is no cycle-exact reference model, on purpose.** A bit-exact predictor
  would have to re-implement the ring, the photodiode and the ADC rounding, and
  would then only be testing itself. The scoreboard checks **properties of the
  closed loop** instead, against the model's internal `detune_code` — which is
  what lets it assert *"the loop locked to the actual resonance"*, a statement
  that is unobservable from the DUT's pins alone.

The headline result of the environment is the coverage cross of the
`SETTLE / tau_cycles` ratio against the lock outcome. It is the axis along which
the archetypal photonic control bug lives: sample the photodiode before the ring
has thermally settled and the loop walks the wrong way and never acquires. The
cross is deliberately left complete — the `(ratio < 1, locked)` cell is exactly
the cell whose appearance would be a finding, so it is not hidden behind an
`ignore_bins`.

## The optical model has a second backend, in C (`+define+RING_DPI`)

Spec §7.2 is implemented twice: once in SystemVerilog (`dv/optics/ring_model.sv`)
and once in C ([`common/dpi`](../../common/dpi), reached over **DPI-C**).
`ring_model` switches between them:

| `ring_model_e` | What evaluates the physics |
|---|---|
| `RING_MODEL_SV` | the SystemVerilog model — **the default for every test in the suite** |
| `RING_MODEL_DPI` | the C model closes the loop; the SV branch is skipped |
| `RING_MODEL_COMPARE` | both, every clock, on identical inputs, checked against each other |

**Why the physics belongs in C.** This is how photonic ICs are actually verified,
not a demonstration of DPI for its own sake. The device model is owned by the
photonics/process team and ships as C — the same code that backs their circuit
simulator flows and their silicon correlation — and it feeds a standalone C
regression, a characterisation script and the link-budget work as well as the
testbench. Rewriting it in SystemVerilog forks the golden model. DV's job is to
*link* to it, and DPI is that bridge. The natural v2 items in [spec §8](docs/photonic_ring_tuner_spec.md#8-out-of-scope-for-v10) —
an FSR comb, thermal crosstalk between rings, laser drift — are lookup tables and
interpolation, which C does well and event-driven `real` arithmetic does not.

**The `RING_DPI` guard means the default build has zero DPI dependency.** Every
`import "DPI-C"` / `export "DPI-C"` and every DPI call in this repository sits
inside `` `ifdef RING_DPI ``. Without the define, `photonics_dpi_pkg` compiles to
an **empty package**, no C symbol is referenced, no shared library is
linked, and `ring_model` has exactly the dependencies it had before the layer
existed — which matters because these UVM runs happen on EDA Playground, which
will not compile user C. Asking for the DPI or COMPARE backend in such a build is
a `UVM_FATAL` naming the missing define, never a silent fall-back: a "DPI
equivalence" run that quietly compared the SV model with itself is the most
expensive kind of green run there is.

**Both directions are exercised.** `import "DPI-C"` for the model calls, and
`export "DPI-C"` for `sv_ring_event`, which the C model calls *back into*
SystemVerilog to report a resonance crossing or an ADC clip. That callback is why
`photonics_ring_step` must be imported **`context`** — an exported function
belongs to a SystemVerilog scope, and only a `context` import carries the scope
the simulator needs to resolve it; a plain import lets the tool drop the
bookkeeping and the callback fails at run time, far from its cause. The
`ring_dpi_*` wrappers exist so every call site is lexically inside the package
that owns the export.

`photonic_ring_tuner_dpi_equiv_test` (`RING_MODEL_COMPARE`) is the acceptance
test for the port; the noise draw stays in SystemVerilog so both backends see the
same sample and the run replays from its seed. Details, the frozen ABI and the
per-simulator linkage are in [`sim/README.md`](sim/README.md#optional-dpi-c-reference-model-definering_dpi--off-by-default)
and [`common/dpi/README.md`](../../common/dpi/README.md). The C model's own unit
tests need **`gcc` only, no simulator** (`make -C common/dpi test`).

## Scope (v1.0)

One resonance is modelled. Free-spectral-range / multi-resonance combs and
wrong-peak lock, thermal crosstalk between adjacent rings, laser wavelength
drift and aging, WDM arbitration, and PID control (v1.0 is fixed-step gradient
ascent) are all explicitly **out of scope**, listed in
[spec §8](docs/photonic_ring_tuner_spec.md#8-out-of-scope-for-v10) so the
boundary is a design decision rather than an oversight.

## Run
See [`sim/README.md`](sim/README.md). Quick start (standalone build — no width define needed):
```sh
make -C sim questa TEST=photonic_ring_tuner_lock_test    # or vcs / xrun
make -C sim regress                                      # all tests x multiple seeds
```

Because the ring is randomized per seed, one seed proves very little — `regress`
runs every test across eight seeds, which is the minimum that should be quoted
as a result.
