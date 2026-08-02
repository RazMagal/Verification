# photonic_ring_tuner — UVM verification environment

Full UVM env for the `photonic_ring_tuner` IP: RAL (multi-field and per-field
mixed-access registers), a **real-number optical model** that closes the control
loop, a property-based scoreboard, functional coverage built around the
settle/tau × lock-outcome cross, a virtual-sequence layer, bound SVA, and a
per-vseq test library. Standard UVM-1.2 / IEEE 1800.2. Mirrors the `apb_gpio`
env structure and reuses `common/apb_vip` unchanged.

## What is here

```
ip/photonic_ring_tuner/
  rtl/photonic_ring_tuner.sv          DUT (owned by the RTL agent; do not modify here)
  rtl/photonic_ring_tuner_sva.sv      tuner SVA (bound onto the DUT)
  dv/optics/ring_if.sv                optical interface: DUT-facing loop +
                                      physical config + detune/temp observables
  dv/optics/ring_model.sv             real-number ring + photodiode + ADC model
                                      (spec §7.2, NON-SYNTHESIZABLE by design)
  dv/photonic_ring_tuner_reg_block.svh  RAL: CTRL/STEP/SETTLE/LOCK_CFG/STATUS/DAC/PD
  dv/photonic_ring_tuner_env_cfg.svh    env config + randomizable ring_cfg
  dv/photonic_ring_tuner_scoreboard.svh the five spec-§7.5 checks
  dv/photonic_ring_tuner_coverage.svh   functional coverage (spec §7.6)
  dv/photonic_ring_tuner_env.svh        env (APB agent + RAL predictor + scb + cov)
  dv/seq/photonic_ring_tuner_vseq_lib.svh  virtual sequences
  dv/test/photonic_ring_tuner_test_lib.svh tests (one per vseq)
  dv/photonic_ring_tuner_pkg.sv         DV package (includes all dv .svh)
  tb/photonic_ring_tuner_tb_top.sv      tb top (clk/rst, ifs, DUT, MODEL, binds)
  sim/run.f  sim/Makefile  sim/README.md
common/apb_vip/                       reused APB VIP (do not modify)
common/dpi/photonics_dpi_pkg.sv       SV side of the OPTIONAL DPI-C ABI
                                      (inert without `+define+RING_DPI`)
common/dpi/photonics_dpi.{h,c}        the C reference model + its own tests
```

## The closed loop (what makes this env different)

The DUT's `adc_code` input is a function of its own `dac_code` output, through
`ring_model`:

```
dut.dac_code --> ring_if --> ring_model (thermal lag, Lorentzian, ADC) --> ring_if.adc_code --> dut
```

So there is **no stimulus sequence to write**. The interesting stimulus is the
*physics*: `ring_cfg` randomizes where the resonance sits, how sharp it is, how
slow the heater is, how bright the laser is; the vseqs then program the loop over
the RAL and **wait for a physical outcome**.

Everything the model does is seeded (`$urandom_range` for the ADC noise, integer
knobs randomized through `randomize()`), so a run reproduces exactly from
`-sv_seed` / `+ntb_random_seed`. `real` cannot be `rand` in SystemVerilog, so
`ring_cfg` randomizes integer knobs and derives the reals in `post_randomize()`.

## Time scaling (spec §7.3 — read this before judging `tau_cycles`)

A real microring's thermal time constant is microseconds to milliseconds; at
100 MHz a faithful `tau` would be 10^5–10^6 clocks and one lock acquisition
would never finish in simulation. `tau_cycles` is therefore **scaled down to
tens of cycles**.

That is sound because the controller cannot observe `tau` in absolute time — it
only ever observes the **ratio `settle_q / tau_cycles`**, i.e. whether it waited
long enough for the ring to reach its new temperature before sampling the
photodiode. Preserving the ratio preserves every bug the loop can have, which is
why the coverage plan bins the **ratio** (and crosses it with the lock outcome)
rather than binning `tau`.

## Compile order (see `run.f`)

Interfaces compile at `$unit` **before** the packages that use their virtual-
interface types:

1. `common/apb_vip/apb_if.sv`, `ip/photonic_ring_tuner/dv/optics/ring_if.sv`
2. `common/dpi/photonics_dpi_pkg.sv` — the DPI-C ABI package, **before** the two
   things that import it (`photonic_ring_tuner_pkg` and `ring_model.sv`). A
   filelist cannot carry an `` `ifdef ``, so the line in `run.f` is
   unconditional and the guard lives *inside* the file: with no
   `+define+RING_DPI` it compiles to an **empty package** and declares no
   `import "DPI-C"` at all, so nothing imports it, nothing links against C, and
   the default flow is untouched.
3. `common/apb_vip/apb_vip_pkg.sv` then `ip/photonic_ring_tuner/dv/photonic_ring_tuner_pkg.sv`
4. `ip/photonic_ring_tuner/dv/optics/ring_model.sv`
5. `ip/photonic_ring_tuner/rtl/photonic_ring_tuner.sv`
6. `common/apb_vip/apb_protocol_checker.sv`, `ip/photonic_ring_tuner/rtl/photonic_ring_tuner_sva.sv`
   (plain-SVA modules, `bind`-ed in the tb top)
7. `ip/photonic_ring_tuner/tb/photonic_ring_tuner_tb_top.sv`

`+incdir` lines in `run.f` point at every directory holding a `.svh`.
Default APB widths (ADDR_WIDTH=8, DATA_WIDTH=32): the standalone build needs
**no** `+define+APB_ADDR_W`.

## Run locally

```
make -C ip/photonic_ring_tuner/sim questa TEST=photonic_ring_tuner_lock_test SEED=3
make -C ip/photonic_ring_tuner/sim vcs    TEST=photonic_ring_tuner_settle_short_test
make -C ip/photonic_ring_tuner/sim xrun   TEST=photonic_ring_tuner_reg_test
make -C ip/photonic_ring_tuner/sim regress        # all tests x 8 seeds (Questa)
```

These are pure SystemVerilog — no `+define+RING_DPI`, no C, no shared library.
The optional DPI-C layer has its own `*_dpi` targets; see
[Optional DPI-C reference model](#optional-dpi-c-reference-model-definering_dpi--off-by-default).

| Test | Ring regime | What it proves |
|------|-------------|----------------|
| `photonic_ring_tuner_smoke_test`        | fixed mid-range | reset values, RW/RO/reserved/W1C behaviour |
| `photonic_ring_tuner_reg_test`          | fixed mid-range | `uvm_reg_hw_reset_seq` + `uvm_reg_bit_bash_seq` |
| `photonic_ring_tuner_error_test`        | fixed mid-range | unmapped/unaligned → `pslverr`; RO writes dropped |
| `photonic_ring_tuner_lock_test`         | LOCKABLE (random) | acquires from cold, lands ON resonance, holds, re-acquires |
| `photonic_ring_tuner_lock_loss_test`    | LOCKABLE (random) | acquires, then the lock is **broken on purpose** (laser off with the loop still enabled): `locked` must deassert, `ACTIVE` stay high, no error flag appear, and the loop re-acquire when the light returns |
| `photonic_ring_tuner_settle_short_test` | SLOW_THERMAL      | **SETTLE < tau ⇒ must NOT lock** (the headline bug) |
| `photonic_ring_tuner_dark_test`         | DARK              | laser off ⇒ `SWEEP_ERR`, never a false lock |
| `photonic_ring_tuner_rail_test`         | RAIL              | resonance past DAC_MAX ⇒ `RAIL_ERR`, saturate not wrap |
| `photonic_ring_tuner_rail_w1c_race_test`| RAIL              | W1C vs HW-set race on `RAIL_ERR` while still railing (spec §3.5) |
| `photonic_ring_tuner_ratio_test`        | LOCKABLE (random) | sweeps settle/tau + dither for the coverage cross |
| `photonic_ring_tuner_dpi_equiv_test`    | LOCKABLE (random) | **needs `+define+RING_DPI`** — full acquisition with the SV and DPI-C optical models in lockstep; they must agree every clock (see below) |

Because the ring is randomized per seed, **one seed proves very little** — the
`regress` target runs every test across eight seeds, which is the minimum that
should be quoted as a result.

### Negative tests carry a liveness requirement

`settle_short`, `dark` and `rail` all assert something that *did not happen*
(`locked` never rose). A verdict of that shape is passed by a DUT that does
nothing at all — `locked` tied low, an FSM that never leaves `S_IDLE`, a dead
photodiode — so each of those tests additionally requires **positive evidence
that the loop ran**: `CTRL.EN` was seen to rise, `STATUS.ACTIVE` was read high,
`dac_code` visited at least half the DAC range, and (on a lit ring) the model
delivered a sample above `MINPOW` while the DUT's own `PD` register read
non-zero. Missing evidence is a `UVM_ERROR` (`SCB_NOT_LIVE` / `VSEQ_NOT_LIVE`),
not a silent pass. The mirror image applies to `lock_test`: the stability check
only counts if the lock was **held** for at least `stability_window/2` clocks.

## Optional DPI-C reference model (`+define+RING_DPI`) — off by default

The optical model can also be evaluated by a C model (`common/dpi`), either
*instead of* the SystemVerilog one or **in lockstep with it**. The whole layer
sits behind one compile guard.

### The compile guard is the point

Every `import "DPI-C"` / `export "DPI-C"` declaration and every DPI call in this
repository is inside `` `ifdef RING_DPI ``. **With the define absent, nothing
changes**: `common/dpi/photonics_dpi_pkg.sv` compiles to an empty package with
no DPI declarations, no C symbol is referenced, no shared library
is linked, and `ring_model.sv` has exactly the dependencies it had before the
layer existed. That is not defensive style — these UVM runs happen on **EDA
Playground, which will not compile your C**, and the existing flow has to keep
working there. *Default flow = no define = pure SystemVerilog.*

The DPI and COMPARE backends are correspondingly **unreachable** without the
define: asking for one produces a `UVM_FATAL` naming the missing define
(`ring_cfg::resolve_model_mode`) and a `$fatal` in `ring_model` if the mode gets
there anyway. Never a silent fallback — a "DPI equivalence" run that quietly
compared the SV model with itself is the most expensive kind of green run there
is.

### Selecting a backend

| `ring_model_e` | What runs |
|---|---|
| `RING_MODEL_SV` | the SystemVerilog physics — **the default for every existing test** |
| `RING_MODEL_DPI` | the C model closes the loop; the SV branch is skipped |
| `RING_MODEL_COMPARE` | both, every clock, on identical inputs, checked against each other |

A test picks one by overriding `ring_model_mode()`; `+RING_MODEL=sv|dpi|compare`
overrides the test. `ring_cfg::resolve_model_mode()` is the single place that
decides, and `ring_model` publishes the backend it **actually ran** on
`ring_if.model_mode_active` — which is what functional coverage
(`cg_acq.cp_backend`) samples, so a regression can *demonstrate* the DPI path
was exercised instead of assuming it. In a build without the define those two
bins are `ignore_bins`'d, because there they are structurally unreachable.

### The randomness stays in SystemVerilog

Exactly one `$urandom_range` draw happens per clock, in `ring_model`, in **every
backend**, and the resulting noise sample is *passed into* `photonics_ring_step`.
The C model must add it verbatim and must never call `rand()` itself: a C-side
RNG is invisible to `-sv_seed` / `+ntb_random_seed`, so a failing run could not
be replayed. And in COMPARE, two models fed *different* noise would disagree for
a reason that has nothing to do with either being wrong.

### `photonics_ring_step` is imported `context` — and why

It calls back into SystemVerilog through the exported `sv_ring_event`. An
exported function belongs to a SystemVerilog **scope**, and only a `context`
import carries the scope the simulator needs to resolve that callback; a plain
import lets the tool skip the bookkeeping and the callback fails at run time,
far from its cause. Same gotcha, second half: the context is the scope the
function is *called from*, so every call goes through the thin `ring_dpi_*`
wrappers in `photonics_dpi_pkg` — lexically inside the same package that owns the
export. Do not call the raw imports from a module.

#### FIRST-RUN CHECK: `context` resolved from a *package* scope

**Read this before trusting the first DPI run on any new simulator.** The design
above assumes a `context` import called from a package function gets *that
package* as its DPI context, so `svGetScope()` inside
`photonics_ring_step` lands on `photonics_dpi_pkg`, where the exported
`sv_ring_event` lives. That is the intent and it is what the LRM's scope rules
describe — but **a package is not an instantiated scope**, and a tool that
instead resolves the context to the *instantiated caller* would hand
`svGetScope()` the `ring_model` instance, where `sv_ring_event` does not exist.
This has never been executed here (there is no simulator in this repo), so treat
the first run as the experiment that settles it.

Symptoms, in the order they are likely to appear:

* a run-time abort on the **first resonance crossing** — typically
  `svGetScope`/`svSetScope`-flavoured: "DPI call outside of a context",
  "exported task/function not found in scope", or an access violation inside the
  simulator's DPI layer. Note *when* it fires: at the first callback, not at the
  first `photonics_ring_step`, which is what distinguishes it from a link error;
* or, on a more forgiving tool, **no abort and no events**: the callback is
  silently dropped. That is what
  `VSEQ_EQUIV_NO_CALLBACK` ("the C model raised ZERO resonance-crossing
  sv_ring_event callbacks") exists to catch — a `UVM_ERROR`, not a mystery.

Diagnosis without a debugger: `make questa_dpi` already writes `vlog`'s own view
of the ABI to `sim/build/photonics_dpi_vlog.h`. Look at the generated
`sv_ring_event` prototype and the scope it is declared under, and diff the file
against the hand-written `common/dpi/photonics_dpi.h`. If the export is emitted
under a scope name that is not `photonics_dpi_pkg`, the assumption above does not
hold on that tool.

The fix, if it is needed, is **on the C side and is small** — before calling
`sv_ring_event`, pin the scope explicitly rather than relying on the inherited
one:

```c
svScope prev = svSetScope(svGetScopeFromName("photonics_dpi_pkg"));
sv_ring_event(ev, value);
svSetScope(prev);          /* restore -- do not leak the scope change */
```

Cache the `svGetScopeFromName()` result (it is a string lookup) and check it for
`NULL`, which would mean the package name is spelled differently in that tool's
scope table. No SystemVerilog change is required either way, which is why none
was made pre-emptively: the wrappers are already in the right scope, and adding
a work-around for a failure no tool here has demonstrated would be guessing.

### The equivalence test

`photonic_ring_tuner_dpi_equiv_test` runs a **full acquisition** in
`RING_MODEL_COMPARE`: cold coarse sweep across the whole DAC range (the entire
Lorentzian, detuning through zero), fine dither lock, hold across the stability
window — the same `RING_EXP_LOCK` verdict `lock_test` carries, so the compared
model must still *close the loop* and not merely be self-consistent. Then, with
the loop disabled and the heater parked, a **corner walk** drives the ring
through what an acquisition never reaches: the resonance crossed in both
directions, `p_peak = 8000` against a 4095-code ADC (the clamp, and the
`RingEvAdcClip` callback), the far tails, a dark fibre and the full noise band.

Both models are IEEE-754 doubles doing the same operations in the same order, so
the quantized `adc_code` must match **exactly**; the pre-quantization reals are
compared with `1e-9 + 1e-12·|ref|`, tight enough to catch a re-derived formula
while tolerating host-FPU excess precision. A mismatch is a `RING_DPI_EQUIV`
`UVM_ERROR` naming the cycle, every input both models were given, and both sets
of outputs (the first 16 in full, the rest counted).

Three further checks stop the result being vacuous, which is the failure mode an
equivalence test is most prone to:

* `equiv_cmp_count` must be **large** — a lockstep check that compared nothing
  passes trivially;
* the C model must have raised **at least one resonance-crossing**
  `sv_ring_event`, since the corner walk provably sweeps `res_code` through the
  parked heater code. Zero crossing callbacks is how a dropped `context`
  presents itself, and spec §7.7(4) makes that event **mandatory**, so it is a
  `UVM_ERROR`. The **clip** event is explicitly *conditional* in the same clause
  — a run whose peak never reaches `adc_max` legitimately never clips — so its
  absence is a `UVM_INFO`. The asymmetry is deliberate and cited at both call
  sites;
* the scoreboard independently re-checks the backend that ran and the mismatch
  total (`SCB_BACKEND` / `SCB_EQUIV` / `SCB_EQUIV_VACUOUS`).

### Running it — linkage differs per simulator, hence one target each

```sh
make -C ip/photonic_ring_tuner/sim vcs_dpi      # VCS: -sv_lib at elaboration
make -C ip/photonic_ring_tuner/sim questa_dpi   # vlog -dpiheader, vsim -sv_lib
make -C ip/photonic_ring_tuner/sim xrun_dpi     # xrun -sv_lib, single step

make -C ip/photonic_ring_tuner/sim regress_dpi      # equivalence test x 8 seeds
make -C ip/photonic_ring_tuner/sim regress_dpi_all  # the WHOLE suite, RING_MODEL=dpi
```

All of them run `make -C common/dpi` first and refuse to start if the shared
library did not appear; override its name with
`DPI_LIBBASE=<path without .so>`. **All three load that one library** — VCS is
*not* handed the `.c` to recompile with its own flags, because an equivalence
result is only worth something if every simulator measured the same binary.

`RING_MODEL=` picks the backend and `DPI_TEST=` (or plain `TEST=`, which the
`*_dpi` targets now honour) picks the test, so any existing test can be re-run
against the C model
(`make questa_dpi DPI_TEST=photonic_ring_tuner_rail_test RING_MODEL=dpi`). With
neither set, the `*_dpi` targets run `photonic_ring_tuner_dpi_equiv_test`.

`questa_dpi` writes `vlog`'s own view of the ABI to `sim/build/`; diffing it
against the hand-written `common/dpi/photonics_dpi.h` is a five-second check for
the classic prototype mismatches (`int` vs `long`, a `real` output that should be
a `double*`, a missing `context`) before they become a run-time crash.

The **default** targets (`questa`, `vcs`, `xrun`, `regress`) are untouched: no
define, no C, and `photonic_ring_tuner_dpi_equiv_test` is deliberately *not* in
the `TESTS` list they iterate.

## Run on EDA Playground

- Language: **SystemVerilog / UVM**, UVM version **1.2**.
- Tool: **Aldec Riviera-PRO** — full UVM/SVA support and the only UVM-capable
  simulator on Playground that needs no account validation. Questa / VCS /
  Xcelium work too, but require a pre-approved institutional email.
- Enable your simulator's **SVA** and **coverage** if you want the bound
  properties and covergroups reported.
- Run/plusargs field: `+UVM_TESTNAME=photonic_ring_tuner_lock_test` (or any test
  above).

Panes (EDA Playground has no `run.f`; paste files respecting the order above —
the site compiles the *Design* pane first, then *Testbench*):

- **Design** pane (RTL + interfaces + the model + plain SVA):
  `apb_if.sv`, `ring_if.sv`, `ring_model.sv`, `photonic_ring_tuner.sv`,
  `apb_protocol_checker.sv`, `photonic_ring_tuner_sva.sv`.
- **Testbench** pane (packages + tb, plus the `.svh` includes reachable via the
  include path): `apb_vip_pkg.sv` and its `.svh` files,
  `photonic_ring_tuner_pkg.sv` and all `dv/**/*.svh`, and
  `photonic_ring_tuner_tb_top.sv` last. Make sure the top module
  `photonic_ring_tuner_tb_top` is the elaboration top.

Note: the `bind` statements live in `photonic_ring_tuner_tb_top.sv`; the two SVA
modules must be compiled (Design pane) so the binds resolve.

**The DPI layer is not usable on Playground and does not need to be.** Do not
set `RING_DPI` there and do not paste `photonics_dpi_pkg.sv` — without the
define it is an empty package, every existing test runs `RING_MODEL_SV`, and the
suite behaves exactly as it did before the layer existed. That constraint is why
the guard exists.

## Design notes

- **RAL prediction is EXPLICIT**: a `uvm_reg_predictor#(apb_seq_item)` is fed by
  the APB monitor; `default_map.set_auto_predict(0)`. `STATUS`, `DAC` and `PD`
  are hardware-updated (volatile) — the mirror may desync, so all three carry
  `NO_REG_BIT_BASH_TEST` and their real behaviour is checked by the scoreboard.
  `STATUS` is per-**field** mixed (`LOCKED`/`ACTIVE` RO, `RAIL_ERR`/`SWEEP_ERR`
  W1C), and `STEP` / `LOCK_CFG` pack two independently programmable fields per
  word, so the RAL exercises field-level access policies, not register-level ones.
- **No cycle-exact reference model, on purpose.** The DUT's input is a
  continuous-valued function of its own output; a bit-exact predictor would have
  to re-implement the ring, the photodiode and the ADC rounding, and would then
  only be testing itself. The scoreboard instead checks **properties of the
  closed loop** — acquisition inside a deadline *derived from the programmed
  registers*, accuracy against the model's internal `detune_code`, stability of
  the DAC while locked, no false lock on a dark ring, and saturation-without-wrap
  at the rail.
- **Tolerances**: the only tolerance in the env is physical and explicit —
  `|detune_code| <= fwhm_code/2` for accuracy, and `span(dac_code) <=
  6*dither_eff` for stability (the spec's ±2·dither_eff on the internal `dac_q`
  plus the ±dither_eff probe excursion that is visible on the pin). Everything
  else — error flags, register readback, `pslverr` — is compared exactly.
- **The `RAIL_ERR` W1C race needs its own test.** `rail_vseq` and `dark_vseq`
  disable the loop before clearing their sticky flag, so the clear is
  deterministic — but hardware can then never re-set the bit and the spec-§5
  cover point `c_w1c_race_rail` is unreachable. `rail_w1c_race_vseq` keeps the
  loop enabled and railing (so `rail_set` fires once per fine iteration),
  shortens `SETTLE` to 4 and programs `THRESH = 0` so the loop can never call
  the rail "at peak", and hammers hundreds of jittered W1C writes at
  `STATUS.RAIL_ERR`. Software must not be able to clear a live hardware
  condition: the bit reads back set every time.
- **The negative tests are constrained to be deterministic.** Each regime in
  `ring_cfg` violates exactly one precondition of acquisition (thermal settling,
  light, reachability), with margins worked out in the constraint comments, so
  "must not lock" is a real assertion rather than a hopeful one. And because a
  purely negative assertion is passed by a DUT that does nothing, each of them
  is paired with the liveness evidence described above — `settle_short` in
  particular also requires that the coarse sweep did **not** end in `SWEEP_ERR`,
  so it can only pass by demonstrating the thermal-lag failure it claims rather
  than degenerating into the dark-ring case.
- **The C model is a suspect, not a reference.** The DPI layer never replaces
  the SystemVerilog model in the default flow; `RING_MODEL_COMPARE` runs the two
  side by side and *the SV model drives the loop*, so a broken C model produces a
  localized stream of `RING_DPI_EQUIV` errors naming the first failing cycle and
  its inputs, rather than a garbage acquisition whose cause is three abstraction
  layers away. The C model is still evaluated on every one of those clocks — it
  is being measured, not bypassed. This is the shape of the real task: qualifying
  somebody else's model against one you already trust.
- **Coverage crosses are honest, not padded.** `x_ratio_outcome` and `x_step`
  both contain cells no stimulus in this suite can reach (the regime that
  produces an outcome also pins the settle/tau ratio; the suite only moves one
  `STEP` field off nominal at a time). Those cells carry `ignore_bins` with the
  reason stated inline, so the remaining percentage means something — while
  every `(ratio, locked)` cell stays in, because `(ratio < 1, locked)` appearing
  would be a finding.
