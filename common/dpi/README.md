# `common/dpi` — the photonics DPI-C layer

The C side of the optical model used by
[`ip/photonic_ring_tuner`](../../ip/photonic_ring_tuner): a microring
resonator, its monitor photodiode, and the ADC, implemented in C and exported to
SystemVerilog over **DPI-C**.

| File | Role |
|------|------|
| `photonics_dpi.h` | the frozen ABI + DPI type mapping + the `context` rule |
| `photonics_dpi.c` | the model (spec §7.2 maths, in the spec's order) |
| `test/test_photonics_dpi.c` | standalone unit tests — **no simulator needed** |
| `Makefile` | `make` (sim lib), `make standalone`, `make test`, `make test-asan`, `make info`, `make clean` |

It is the C twin of [`dv/optics/ring_model.sv`][ringmodel]. Both implement spec
§7.2 with the same operations in the same order, on IEEE-754 doubles (SV `real`
*is* a double), so the two can be compared **sample for sample** — that
equivalence run is the acceptance test for the port.

[ringmodel]: ../../ip/photonic_ring_tuner/dv/optics/ring_model.sv

---

## Why the physics belongs in C

This is not an exercise in using DPI for its own sake. It is how photonic ICs
are actually verified:

- **The device model is owned by the photonics/process team, not by DV.** They
  ship a C (or C++/Python-wrapped-C) model of the ring — the same code that
  backs their circuit simulator flows and their silicon correlation. It is not
  written in SystemVerilog, and rewriting it in SystemVerilog forks the golden
  model. The DV environment's job is to *link* to the model, not to reimplement
  it.
- **One model, many consumers.** The same `.c` feeds the SV testbench, a
  standalone C regression, a Python characterisation script (via `ctypes`), and
  the architects' link-budget spreadsheets. A SystemVerilog model feeds exactly
  one of those. Note that the simulator-less consumers need the *second*
  artifact, `make standalone` — see [Two shared objects](#two-shared-objects)
  below; the library the simulator loads deliberately cannot be `dlopen`ed on
  its own.
- **Real optics gets expensive.** v1.0 is a single Lorentzian, but the natural
  v2 items in spec §8 (the FSR comb, thermal crosstalk between rings, laser
  drift) are lookup tables, interpolation, and matrix work. Event-driven `real`
  arithmetic in SystemVerilog is a poor and slow vehicle for that; C is not.
- **It is testable without a licence.** The whole `test/` suite runs in under a
  second on any machine with `gcc`, which is why the maths is regression-tested
  here and the simulator only ever has to prove the *linkage*.

The trade is that DPI linkage is per-simulator boilerplate (see below) and that
a crash in C takes the simulator with it — hence the NULL-handle and degenerate
config guards on every entry point.

---

## ABI

Frozen. The SV side codes against exactly this.

| C | SystemVerilog | Meaning |
|---|---|---|
| `void* photonics_ring_new(void)` | `chandle` | allocate one ring; `NULL` on failure |
| `void photonics_ring_free(void* h)` | — | release it; `NULL` is a no-op |
| `void photonics_ring_config(void* h, double res_code, double fwhm_code, double tau_cycles, double p_peak_lsb, double noise_lsb, int laser_on, int adc_max)` | 5×`real`, 2×`int` | the spec §7.4 parameters |
| `void photonics_ring_reset(void* h)` | — | cold reset: `temp = 0`, `detune = -res_code` |
| `int photonics_ring_step(void* h, int dac_code, double noise_sample, double* detune_code, double* temp_code)` | returns `int`, two `output real` | **one clock** of update; returns the ADC code |
| `const char* photonics_dpi_version(void)` | `string` | version banner |
| `extern void sv_ring_event(int ev, double value)` | `export "DPI-C"` | callback **into** SV |

Events (`ev`):

| Macro | Value | Fires when | `value` carries |
|---|---|---|---|
| `PHOTONICS_EV_RESONANCE_CROSS` | 0 | `detune_code` changed sign | the new detuning |
| `PHOTONICS_EV_ADC_CLIP` | 1 | the quantizer clamped at `adc_max` | the unquantized `adc_r` |

Type mapping: `chandle`↔`void*`, `int`↔`int`, `real`↔`double`, `output real`↔
`double*`, `string` return↔`const char*`. **No `svdpi.h` type appears in the
ABI** — deliberately, so the model builds and its tests run with plain `gcc`.

### The SV declarations

Copy these verbatim — this block is what `photonics_dpi_pkg.sv` declares.
**Exactly one import is `context`, and it is the one that needs to be.**

```systemverilog
import "DPI-C" function chandle photonics_ring_new();
import "DPI-C" function void    photonics_ring_free(input chandle h);
import "DPI-C" function void    photonics_ring_config(
    input chandle h, input real res_code, input real fwhm_code,
    input real tau_cycles, input real p_peak_lsb, input real noise_lsb,
    input int laser_on, input int adc_max);
import "DPI-C" function void    photonics_ring_reset(input chandle h);

// `context` is MANDATORY here: this is the import that calls back into SV.
import "DPI-C" context function int photonics_ring_step(
    input chandle h, input int dac_code, input real noise_sample,
    output real detune_code, output real temp_code);

import "DPI-C" function string  photonics_dpi_version();

export "DPI-C" function sv_ring_event;   // implemented in SV, called from C
```

**`photonics_ring_step` must be imported `context`.** It calls back into
SystemVerilog through `sv_ring_event`, and a non-`context` import gives that
callback no SV scope to execute in: simulators either error at elaboration or
resolve the export against whatever scope happens to be current. The `export`
must live in the same scope (module or package) that owns the ring.

The other five imports are **not** `context`, deliberately. `context` is not
free decoration: it makes the simulator save and restore the DPI scope around
every call, and — more to the point here — marking an import `context` when it
never calls an export tells the next reader the wrong thing about which call is
the dangerous one. Keep the qualifier where it is load-bearing, so that when
somebody deletes it by accident the diff is obvious.

### Semantics worth knowing

- **One `_step` = one clock**, in spec §7.2 order: thermal lag → detuning →
  Lorentzian → photodiode/ADC quantize+clamp. The ADC code returned is produced
  by the `temp` computed *in that same call*. Reordering shifts the loop's phase
  by a clock and silently corrupts the `settle_q / tau_cycles` ratio that spec
  §7.6 builds its headline coverage cross on.
- **Degenerate config is clamped, not rejected**, identically to the SV model:
  `tau_cycles < 1.0 → 1.0`, `fwhm_code < 1.0 → 1.0`, plus `adc_max < 1 → 1`
  (`adc_max` is a `localparam` in SV and cannot go bad there; over DPI it is an
  argument). Each warns once per instance. Note the band `0 < tau < 1`: it does
  not divide by zero, so a guard written as `tau <= 0` lets it through and the
  discrete lag then *overshoots* the drive. Clamping at `1.0` is the SV model's
  behaviour and is what the unit tests pin down.
- **Non-finite parameters are replaced at `_config`**, so a stray NaN cannot
  poison `temp` for the rest of the run and cannot reach the `(int)` cast in the
  quantizer (which would be undefined behaviour).
- **Negative values never reach the unsigned quantizer**: `adc_r <= 0` returns
  code 0. That bottom clamp does *not* raise `ADC_CLIP` — on a dark ring
  negative noise clamps most samples, so an event there would fire continuously
  and tell the scoreboard nothing. `ADC_CLIP` means *saturation at the top*.
- **`_config` never touches thermal state; `_reset` always clears it.** These
  are the two invariants the SV side leans on hardest: `ring_model.sv` calls
  `ring_dpi_config` on *every* step (so a `_config` that cleared `temp` would
  kill the thermal lag and the DUT would never lock) and re-resets the handle on
  *every* reset edge (so a `_reset` that left the heater warm would mismatch the
  SV model on every cycle after it). Both are pinned by dedicated test sections.
- **Events are emitted last**, after the handle state and the output arguments
  are committed, because the callback runs arbitrary SV and could re-enter.
- **The handle is per-instance.** No global holds model state, so a multi-ring
  testbench (v2's thermal-crosstalk work) just allocates more handles.

---

## The RNG stays in SystemVerilog

`photonics_ring_step` takes `noise_sample` **as an argument**: the read noise is
drawn and scaled on the SV side and passed in. This layer contains **no RNG at
all** — no `rand()`, no `random()`, no `srand()`.

That is a deliberate DV decision, not an oversight. `ring_model.sv` draws its
noise with `$urandom_range`, i.e. from the **simulator's seed domain**, so every
run reproduces exactly from the UVM seed (`+ntb_random_seed` / `-sv_seed` /
`-svseed`). If C drew the noise from libc instead, the sequence would come from
a generator the simulator neither seeds nor records: two runs of the same seed
would diverge, and **a failing regression could not be replayed** — which is the
one property a DV environment cannot give up. Randomisation lives where the seed
lives.

Two consequences the SV side must honour:

1. `noise_sample` is in **ADC LSBs, already scaled** by the noise amplitude.
2. It is **ignored when `noise_lsb <= 0`**, mirroring `ring_model.sv`'s
   `uniform_noise()` returning `0.0` for `amp <= 0.0`. Without that gate a
   testbench that always scales its own sample would inject noise into a run
   configured for none, and the C/SV bit comparison would fail.

---

## Build and test

```sh
cd common/dpi
make            # -> libphotonics_dpi.so             (for a SIMULATOR to load)
make standalone # -> libphotonics_dpi_standalone.so  (dlopen / ctypes)
make test       # builds AND runs the unit tests, non-zero exit on failure
make test-asan  # the same tests under AddressSanitizer + UBSan
make info       # shows the compiler and whether an svdpi.h was found
make clean
```

Everything is warnings-clean under `-Wall -Wextra -Wpedantic -Wshadow
-Wstrict-prototypes` (and, as it happens, `-Wconversion`).

### Two shared objects

They are **not** interchangeable, and the difference is one symbol:

| Artifact | `sv_ring_event` | Loadable by | Not loadable by |
|---|---|---|---|
| `libphotonics_dpi.so` | **undefined** | a simulator (`vsim -sv_lib`, `xrun -sv_lib`, VCS) — it *defines* the symbol from the SV `export` | `dlopen`/`ctypes`/any plain process |
| `libphotonics_dpi_standalone.so` | stub, linked in | `dlopen`, Python `ctypes`, a fuzzer, a C harness | never give this one to a simulator |

`ctypes.CDLL("./libphotonics_dpi.so")` fails with `undefined symbol:
sv_ring_event`, and that is **correct**: the symbol belongs to the simulator.
Forcing it open with `RTLD_LAZY` is worse — it loads, then hard-aborts the
process the first time the ring crosses resonance and the model calls a symbol
that was never bound. Simulator-less consumers use the standalone build:

```python
import ctypes
lib = ctypes.CDLL("./libphotonics_dpi_standalone.so")   # NOT libphotonics_dpi.so
lib.photonics_ring_new.restype = ctypes.c_void_p
lib.photonics_ring_config.argtypes = ([ctypes.c_void_p] + [ctypes.c_double] * 5
                                      + [ctypes.c_int] * 2)
lib.photonics_ring_step.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_double,
                                    ctypes.POINTER(ctypes.c_double),
                                    ctypes.POINTER(ctypes.c_double)]
h = lib.photonics_ring_new()
lib.photonics_ring_config(h, 1000.0, 512.0, 4.0, 3000.0, 0.0, 1, 4095)
lib.photonics_ring_reset(h)
d = ctypes.c_double(); t = ctypes.c_double()
adc = lib.photonics_ring_step(h, 2000, 0.0, ctypes.byref(d), ctypes.byref(t))
lib.photonics_ring_free(h)
```

The standalone build also exports `photonics_standalone_event_count(int ev)` and
`photonics_standalone_event_reset()` so a script can still see the event path.
Those two are **not** part of the frozen DPI ABI and do not exist in the
simulator artifact.

The obvious-looking shortcut — one library with a **weak** `sv_ring_event`, so
it always links — is deliberately rejected. Weak-symbol preemption depends on
load order and on the simulator exporting its DPI symbols globally, which not
every tool does; where preemption does not happen the library links cleanly,
runs, and drops **every** event on the floor. Spec §7.7(4) makes a silently dead
event path a must-fail, and one that presents as "the scoreboard never saw a
crossing" costs days. An undefined symbol fails at load time instead, which is
the cheapest possible failure.

### What the tests cover

`make test` links the model against a local `sv_ring_event` stub and needs **no
simulator, no svdpi.h and no licence**. It covers the Lorentzian at `d = 0` and
`|d| = fwhm/2`, the thermal lag against its closed form `D·(1 − (1 − 1/τ)ⁿ)`,
both ADC rails and the clip event's saturation-vs-rounding boundary, the dark
ring, the noise gate, every degenerate configuration, one-event-per-crossing
(including landing exactly on `d == 0`), NULL-handle safety, instance
independence, and the two state invariants below. Current status: **98 checks in
11 sections, 0 failures**.

Two of those sections exist because the rest of the suite was blind to them —
both mutations survived an earlier 83-check run:

- **`_reset` must clear a HOT heater.** Every other reset in the suite used
  `tau = 1` (where the lag is a pass-through) or reset an already-cold ring, so
  deleting `temp = 0.0` changed nothing. The section heats a `tau = 8` ring to
  1000, resets, and requires `temp == 0.0` *exactly* on the next step; the buggy
  version yields 875. It matters because `ring_model.sv` re-resets the handle on
  every reset edge — a C model still warm at reset mismatches the SV model on
  every subsequent cycle.
- **`_config` must NOT clear the integrator.** `ring_model.sv` re-publishes the
  whole parameter set through `ring_dpi_config` **every step**, so a `temp = 0`
  in `_config` would restart the thermal lag each cycle and the DUT would never
  lock. The section reconfigures mid-charge with `tau > 1` and requires the
  integration to continue (487.09, not 125), then runs a ring reconfigured
  before *every* step against a reference configured once and requires the two
  trajectories to agree bit for bit over 60 cycles.

The suite is otherwise mutation-checked: reordering the lag against the
Lorentzian, dropping the factor 2 in `2·d/fwhm`, using `|x|` instead of `x²`,
truncating instead of rounding, removing the noise gate, weakening either clamp
to `<= 0`, and dropping the crossing sign-latch are each caught by at least one
check.

`make test-asan` is not a duplicate run: it is the only thing that checks the
ABI's **memory** contract rather than its physics. Reducing
`photonics_ring_free` to a no-op passes `make test` with all 98 checks green and
fails `test-asan` with `LeakSanitizer: detected memory leaks … 1632 byte(s) in
17 allocation(s)`. It also builds with `-fno-sanitize-recover=undefined`, so any
UB is a failure rather than a printed note.

`svdpi.h` is included when found (`-DPHOTONICS_DPI_HAVE_SVDPI`, or via
`__has_include`); the Makefile probes `$PHOTONICS_SVDPI_DIR`, `$VCS_HOME`,
`$QUESTA_HOME`, `$MTI_HOME`, `$MODEL_TECH`, `$XCELIUM_HOME`, `$CDS_INST_DIR`
and the system include dirs. Nothing breaks when it is absent. The probe runs in
the shell with every candidate quoted, because vendor installs really do live in
paths with spaces (`/opt/Questa Sim 2023.4/include`) and make's `$(wildcard)`
would word-split those into oblivion; setting `PHOTONICS_SVDPI_DIR` to a
directory that holds no `svdpi.h` warns rather than being ignored.

---

## Linking it into a simulator

DPI linkage is the one genuinely non-portable part. Each vendor differs:

**Synopsys VCS** — put the `.c` straight on the command line; VCS compiles and
links it into `simv` for you:

```sh
vcs -full64 -sverilog -ntb_opts uvm-1.2 -f run.f common/dpi/photonics_dpi.c
```

For a prebuilt shared object instead: `-LDFLAGS "-L common/dpi -lphotonics_dpi"`
(and set `LD_LIBRARY_PATH`). `-dpiheader hdr.h` emits the C prototypes VCS
expects, which is the quickest way to diagnose a signature mismatch.

**Mentor/Siemens Questa** — two steps, and the shared library is loaded at
*elaboration*, not compile:

```sh
vlog -sv -dpiheader dpi_types.h -f run.f     # exports -> dpi_types.h
make -C common/dpi                            # -> libphotonics_dpi.so
vsim -c -sv_lib common/dpi/libphotonics_dpi photonic_ring_tuner_tb_top -do "run -all"
```

Note `-sv_lib` takes the path **without** the `.so` — vsim appends the platform
extension itself. Passing `libphotonics_dpi.so` is the classic "cannot find
library" error.

**Cadence Xcelium** — `xrun` accepts either form, but the `.so` must be built
with the same ABI; `-sv_lib` here *does* take the full filename:

```sh
xrun -64bit -sv -uvm -f run.f common/dpi/photonics_dpi.c        # xrun compiles it
xrun -64bit -sv -uvm -f run.f -sv_lib common/dpi/libphotonics_dpi.so   # or prebuilt
```

`-dpiheader` exists here too, and Xcelium is the strictest of the three about
the `context` qualifier on imports that call exports.

**EDA Playground (Riviera-PRO)** — out of reach. The browser flow has only a
*Design* and a *Testbench* pane, with no way to add a C file to the compile, so
this layer cannot be exercised there. That is exactly why `ring_model.sv` stays
the default optical model in `sim/run.f` and the C model is the linked-in
alternative: the SV path keeps the whole environment runnable on Playground,
and the C path is what a real photonics flow would use. Their bit-for-bit
agreement is what makes swapping one for the other safe.
