# `photonic_ring_tuner` — Specification (verification contract)

A **silicon-photonic microring resonance-lock controller** on an APB3 slave port: it
drives a thermal (heater) DAC and reads a monitor photodiode through an ADC, and its
job is to park the ring's optical resonance on the laser line and hold it there.

This document is the **single source of truth** shared by the RTL (`rtl/`) and the UVM
DV environment (`dv/`): the port list, register map, FSM behaviour, the **internal
signal names** the bound SVA relies on, and the **real-number optical model** the DV
environment closes the loop with are all fixed here.

Style and conventions mirror
[`../../apb_gpio/docs/apb_gpio_spec.md`](../../apb_gpio/docs/apb_gpio_spec.md).

---

## 0. Why this block exists (informative)

A microring resonator only passes light at wavelengths matching its resonance. That
resonance moves with temperature and with process variation — tens of linewidths of
drift is normal — so a fabricated ring is essentially *never* aligned to its laser at
power-up. Every silicon-photonic link therefore ships a **digital** control loop that
heats the ring until its resonance sits on the laser line, then holds it there.

That loop is the DUT. The optics themselves are continuous physics and cannot be
simulated by an event-driven digital simulator, so the DV environment supplies a
**real-number model** (§7) of the ring, the photodiode, and the ADC, and the loop
closes through it. This is the standard way photonic ICs are verified: you verify the
electronic control plane against a behavioural model of the optical device.

The controller runs in two phases, as real tuners do:

1. **Coarse sweep** — ramp the heater DAC across its full range, record the code that
   produced the most light. Gradient descent cannot start cold, because far from
   resonance the photodiode signal is flat and the gradient is buried in noise.
2. **Fine dither lock** — closed-loop peak tracking. Probe one dither step above and
   one below the current code, move toward the brighter probe, and declare lock when
   the two probes are equal to within a threshold *and* both are above a minimum
   power.

The minimum-power qualifier in phase 2 is not optional. The two probes are also equal
in the **flat region far off resonance** (both read ≈ 0), so a lock rule based on
gradient alone declares a **false lock** on a dark ring. §3.4 makes this explicit
because it is the first thing this block must be proven not to do.

---

## 1. Interface

```systemverilog
module photonic_ring_tuner #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32,   // APB data width
    parameter int DAC_WIDTH  = 12,   // heater DAC resolution
    parameter int ADC_WIDTH  = 12,   // photodiode ADC resolution
    parameter int LOCK_N     = 4     // consecutive at-peak iterations to declare lock
) (
    apb_if.slave                 apb,       // reuses common/apb_vip apb_if (slave modport)
    input  logic [ADC_WIDTH-1:0] adc_code,  // photodiode reading (unsigned, free-running)
    output logic [DAC_WIDTH-1:0] dac_code,  // heater DAC drive
    output logic                 locked     // active-high level: loop is locked
);
```

- Clock/reset come from `apb.clk` / `apb.rst_n` (active-low, async assert,
  **synchronous de-assert**), same as `apb_timer` and `apb_gpio`.
- APB is a single-cycle slave (combinational `pready = 1`): SETUP → ACCESS,
  `pslverr` on an illegal address. Identical protocol handling to `apb_gpio`.
- `adc_code` is **free-running and always valid** — the ADC converts continuously and
  the controller samples it when it chooses. There is no handshake. (A real part has a
  conversion-done strobe; v1.0 abstracts it away deliberately.)
- `dac_code` is driven **every cycle**, including during reset (`0`) and while idle.
  A heater DAC has no high-impedance state.
- `DAC_MAX = 2**DAC_WIDTH - 1`, `DAC_MIN = 0`. There are no programmable rails in v1.0.
- **Legal parameterization**, checked at *elaboration* (a violation is a `$fatal`, not
  a silently mis-built loop): `DATA_WIDTH = 32` — pinned by the §2 packed-field
  layout; `ADDR_WIDTH ≥ 5` — must map `0x00..0x18`; `LOCK_N ≥ 1`;
  `1 ≤ DAC_WIDTH ≤ DATA_WIDTH`; `1 ≤ ADC_WIDTH ≤ 19`. That ADC upper bound comes from
  the `MINPOW` **reset**: it is `full-scale/16` and `LOCK_CFG.MINPOW` is a 16-bit
  field, so `ADC_WIDTH = 20` would need `2**16` and no fraction of full scale worth
  having would fit (§2). The widths of the *connected* `apb_if` are checked separately
  from these parameters — nothing forces an interface instance to agree with them.

---

## 2. Register map (byte offsets in `[0x00 .. 0xFF]`)

| Offset | Name       | Access | Reset        | Description                                        |
|--------|------------|--------|--------------|----------------------------------------------------|
| `0x00` | `CTRL`     | RW     | `0`          | `[0] EN` — enable the loop. See §3.1.              |
| `0x04` | `STEP`     | RW     | `0x0000_2004`| `[7:0] DITHER`, `[15:8] SWEEP` — step sizes in DAC LSBs. |
| `0x08` | `SETTLE`   | RW     | `0x0000_0020`| `[15:0]` — clocks to wait after moving the DAC before sampling the ADC. |
| `0x0C` | `LOCK_CFG` | RW     | `{2**(ADC_WIDTH-4), 16'h0008}`<br>= `0x0100_0008` at the default `ADC_WIDTH = 12` | `[15:0] THRESH`, `[31:16] MINPOW` — lock criteria in ADC LSBs. `MINPOW` resets to **ADC full-scale/16**; `THRESH` resets to an **absolute** `8` LSBs. See *Why `MINPOW` scales* below. |
| `0x10` | `STATUS`   | mixed  | `0`          | `[0] LOCKED` RO, `[1] RAIL_ERR` W1C, `[2] SWEEP_ERR` W1C, `[3] ACTIVE` RO. |
| `0x14` | `DAC`      | RO     | `0`          | `[DAC_WIDTH-1:0]` — current centre code `dac_q`.   |
| `0x18` | `PD`       | RO     | `0`          | `[ADC_WIDTH-1:0]` — most recent ADC sample `pd_q`, updated in **every** sample state (§3.3, §3.4). |

Any other offset in `[0x00 .. 0xFF]` → **illegal access** → `pslverr = 1`,
`prdata = 0`. A write to a RO register (`DAC`, `PD`) or to a RO field is **silently
dropped** (no `pslverr`, no effect), matching `apb_gpio`'s RO `DATA_IN` behaviour.
Reserved bits read as `0` and ignore writes.

`STATUS` mixes access types within one register — `LOCKED`/`ACTIVE` are read-only live
hardware state, `RAIL_ERR`/`SWEEP_ERR` are sticky W1C error flags. This mirrors real
silicon and exercises per-field RAL access policies.

**Effective step sizes.** A programmed step of `0` would stall the FSM forever, so
both fields are clamped to a minimum of 1 in hardware:
`dither_eff = (DITHER == 0) ? 1 : DITHER`, `sweep_eff = (SWEEP == 0) ? 1 : SWEEP`.
The register still reads back the programmed `0`.

**Why `MINPOW` scales with `ADC_WIDTH` and `THRESH` deliberately does not.**
`MINPOW` is the minimum photodiode reading that qualifies a sweep peak (§3.3) and
gates lock declaration (§3.4). It is physically **a fraction of the expected peak**,
not an absolute LSB count: narrowing the ADC changes the *quantization*, not the
*optics*. Its reset is therefore `full-scale/16 = 2**(ADC_WIDTH-4)`, which is exactly
`256 = 0x100` at the default `ADC_WIDTH = 12` — the value this register always had,
now written as what it always meant. A fixed `0x100` breaks in **both** directions:
at `ADC_WIDTH = 8` full scale is `255`, so `MINPOW` sits *above* full scale and is
unreachable — the loop can never lock at its reset defaults, and every sweep ends in
`SWEEP_ERR`; at `ADC_WIDTH = 16` it is `0.39 %` of full scale, so the false-lock
guard is nearly useless. **The second direction is the dangerous one**, because it
fails *permissively*: a nearly dark ring passes the one check that exists to reject
it (§3.4), and the failure is a confident wrong answer rather than a loud one.

`THRESH` is the opposite case and stays absolute. It discriminates a *real* gradient
from the *noise floor*, and quantization noise is ~0.5 LSB regardless of converter
width — `8/4096` is not a fraction of anything in particular. Scaling it would make
the dead-band track the wrong quantity.

Clamps, so the formula is total for every legal parameterization: the reset is
floored at `1` (`2**(ADC_WIDTH-4)` rounds to 0 below `ADC_WIDTH = 5`, and a `MINPOW`
of 0 is not a false-lock guard at all) and never exceeds full scale. `MINPOW` is a
16-bit field, so `ADC_WIDTH ≥ 20` could not express `full-scale/16` at all — that is
**rejected at elaboration** (§1 parameter checks) rather than silently clamped, since
a clamped `MINPOW` is precisely the permissive failure above.

---

## 3. Behaviour

### 3.1 Enable and phases

- A **rising edge of the registered `en_q`** (not a level, and not the write itself)
  **starts a fresh acquisition**: `dac_q ← 0`, sweep bookkeeping cleared, FSM enters
  the coarse sweep. It does *not* clear the sticky error flags.
- Because the trigger is an edge, a sweep that ends in `SWEEP_ERR` **parks in `S_IDLE`
  until software re-arms it** (`EN` 1→0→1) rather than spinning forever on a dark
  ring. Taking the edge off `en_q` is also what makes assertion §5.5 exact.
- `CTRL.EN` `1 → 0` returns the FSM to `S_IDLE` immediately, clears `locked_q` and the
  lock counter, and **holds `dac_q` at its current value** — a real heater keeps its
  bias when the loop is disabled.
- **Disabling gates loop *actuation*, not just the state.** On the clock that aborts a
  transfer, the FSM must not move `dac_q`, must not advance the sweep, and must not
  latch `RAIL_ERR` or `SWEEP_ERR` from loop activity. Clearing `locked_q` alone is not
  sufficient: an ungated datapath still commits one final dither move (and can set
  `RAIL_ERR`) on the aborting edge, which contradicts "holds `dac_q`" above. Passive
  observation (`pd_q`/`p_hi_q`/`p_lo_q` capture) is *not* gated — it is a record of the
  ADC, not an actuation. Already-set sticky flags are of course not cleared.
- `ACTIVE` (STATUS[3]) reads `1` whenever the FSM is not in `S_IDLE`.

### 3.2 FSM

Eight states, encoded exactly as below (fixed so the bound SVA can decode `state_q`
without importing an enum type):

| Encoding | State          | Drives `dac_code`     | Action                                              |
|----------|----------------|-----------------------|-----------------------------------------------------|
| `3'd0`   | `S_IDLE`       | `dac_q`               | Wait for `EN`.                                      |
| `3'd1`   | `S_SWEEP_WAIT` | `dac_q`               | Count `settle_q` clocks.                            |
| `3'd2`   | `S_SWEEP_SAMP` | `dac_q`               | Sample; update best; advance or finish sweep.       |
| `3'd3`   | `S_HI_WAIT`    | `dac_q + dither_eff`  | Count `settle_q` clocks.                            |
| `3'd4`   | `S_HI_SAMP`    | `dac_q + dither_eff`  | Capture `p_hi_q`.                                   |
| `3'd5`   | `S_LO_WAIT`    | `dac_q - dither_eff`  | Count `settle_q` clocks.                            |
| `3'd6`   | `S_LO_SAMP`    | `dac_q - dither_eff`  | Capture `p_lo_q`.                                   |
| `3'd7`   | `S_UPDATE`     | `dac_q`               | Compare probes, move `dac_q`, update lock counter.  |

All eight encodings are legal — there is no reachable illegal state.

**Probe drive is clamped, never wrapped.** In `S_HI_*` the DAC is driven at
`min(dac_q + dither_eff, DAC_MAX)`; in `S_LO_*` at `max(dac_q - dither_eff, DAC_MIN)`,
computed with enough width that the intermediate sum cannot overflow.

Each `*_WAIT` state counts `settle_q` clocks (a programmed `SETTLE` of 0 means sample
on the next clock — no wait). `settle_cnt_q` resets to 0 on every state entry.

### 3.3 Coarse sweep (`S_SWEEP_WAIT` / `S_SWEEP_SAMP`)

On entry: `dac_q ← 0`, `best_adc_q ← 0`, `best_code_q ← 0`.

In `S_SWEEP_SAMP`:
1. `pd_q ← adc_code`.
2. If `adc_code > best_adc_q` then `best_adc_q ← adc_code`, `best_code_q ← dac_q`.
3. If `dac_q + sweep_eff > DAC_MAX` the sweep is **complete**:
   - if the best sample (including the one just taken) `>= MINPOW` →
     `dac_q ← best_code_q` and go to `S_HI_WAIT`;
   - else → `sweep_err_q ← 1`, go to `S_IDLE`.
   
   > **Implementation hazard:** the completion test must use the *next* value of
   > `best_adc_q`/`best_code_q`, not the registered value, or the final sweep point is
   > ignored. Compute both from a combinational next-value.
4. Otherwise `dac_q ← dac_q + sweep_eff`, go to `S_SWEEP_WAIT`.

`SWEEP_ERR` means "no resonance found anywhere in the tuning range" — laser off, fibre
unplugged, photodiode dead, or `MINPOW` set above the achievable peak.

### 3.4 Fine dither lock (`S_HI_*` / `S_LO_*` / `S_UPDATE`)

With `p_hi_q` and `p_lo_q` captured, in `S_UPDATE`:

```
move_up   = (p_hi_q  > p_lo_q + THRESH)
move_down = (p_lo_q  > p_hi_q + THRESH)
at_peak   = !move_up && !move_down && (p_hi_q >= MINPOW) && (p_lo_q >= MINPOW)
```

- `move_up`   → `dac_q ← dac_q + dither_eff`, saturating at `DAC_MAX`; if the move
  saturated, `rail_err_q ← 1`.
- `move_down` → `dac_q ← dac_q - dither_eff`, saturating at `DAC_MIN`; if the move
  saturated, `rail_err_q ← 1`.
- otherwise `dac_q` is unchanged.

Lock counter, then unconditionally back to `S_HI_WAIT`:

```
lock_cnt_q ← at_peak ? min(lock_cnt_q + 1, LOCK_N) : 0
locked_q   ← (lock_cnt_q reaches LOCK_N)
```

`locked_q` therefore **deasserts as soon as a single iteration is not at peak** — it
is a live status, not sticky. It drives both `STATUS.LOCKED` and the `locked` port.

> **The `MINPOW` term is what prevents a false lock.** Far off resonance the
> transmission curve is flat, so `p_hi_q ≈ p_lo_q ≈ 0` and the gradient test alone
> reports "at peak" on a completely dark ring. Requiring both probes to exceed
> `MINPOW` rejects that. §7.4 defines the test that proves it.
>
> This is why `MINPOW`'s reset is a *fraction of full scale* (`2**(ADC_WIDTH-4)`,
> §2) rather than a fixed LSB count: a `MINPOW` that does not track the converter
> ends up a negligible fraction of full scale on a wider ADC, and then this
> paragraph's guard silently stops guarding — the ring is dark, both probes are
> "above `MINPOW`", and the block declares the exact false lock it exists to
> refuse. That failure is *permissive*, so nothing reports it.

### 3.5 Sticky error flags

`RAIL_ERR` and `SWEEP_ERR` are set by hardware and cleared **only** by a write-1-to-
clear to `STATUS`. If a hardware set and a W1C to the same bit land on the same clock,
the bit **stays set** (HW-set-wins), identical to `apb_timer`/`apb_gpio` STATUS.

### 3.6 Reset

Active-low `apb.rst_n`, async assert / sync de-assert. All registers take their §2
reset values; `state_q ← S_IDLE`, `dac_q ← 0`, `pd_q ← 0`, `locked_q ← 0`,
`lock_cnt_q ← 0`, `settle_cnt_q ← 0`, `best_*_q ← 0`; `dac_code` drives `0`.

---

## 4. Internal signal names (fixed — for the bound SVA)

The RTL **must** use exactly these names:

| Signal         | Width               | Meaning                                     |
|----------------|---------------------|---------------------------------------------|
| `state_q`      | `[2:0]`             | FSM state, encoded per §3.2                 |
| `dac_q`        | `[DAC_WIDTH-1:0]`   | Centre code (the `DAC` register)            |
| `pd_q`         | `[ADC_WIDTH-1:0]`   | Last ADC sample (the `PD` register)         |
| `p_hi_q`       | `[ADC_WIDTH-1:0]`   | Upper probe sample                          |
| `p_lo_q`       | `[ADC_WIDTH-1:0]`   | Lower probe sample                          |
| `best_adc_q`   | `[ADC_WIDTH-1:0]`   | Best sample seen during the sweep           |
| `best_code_q`  | `[DAC_WIDTH-1:0]`   | DAC code that produced `best_adc_q`         |
| `lock_cnt_q`   | `[$clog2(LOCK_N+1)-1:0]` | Consecutive at-peak iterations         |
| `locked_q`     | 1                   | `STATUS.LOCKED`                             |
| `rail_err_q`   | 1                   | `STATUS.RAIL_ERR` (sticky)                  |
| `sweep_err_q`  | 1                   | `STATUS.SWEEP_ERR` (sticky)                 |
| `en_q`         | 1                   | `CTRL.EN`                                   |
| `dither_q`     | `[7:0]`             | `STEP.DITHER` as programmed                 |
| `sweep_q`      | `[7:0]`             | `STEP.SWEEP` as programmed                  |
| `settle_q`     | `[15:0]`            | `SETTLE`                                    |
| `thresh_q`     | `[15:0]`            | `LOCK_CFG.THRESH`                           |
| `minpow_q`     | `[15:0]`            | `LOCK_CFG.MINPOW`                           |
| `settle_cnt_q` | `[15:0]`            | Settle-wait counter                         |

Plus the module ports `adc_code`, `dac_code`, `locked`.

---

## 5. Assertions (bindable `photonic_ring_tuner_sva`, plain SVA)

Module header (fixed, so `tb_top` can bind by name):

```systemverilog
module photonic_ring_tuner_sva #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32,
    parameter int DAC_WIDTH  = 12,
    parameter int ADC_WIDTH  = 12,
    parameter int LOCK_N     = 4
) (
    input logic clk, rst_n,
    input logic [2:0]            state_q,
    input logic [DAC_WIDTH-1:0]  dac_q, dac_code, best_code_q,
    input logic [ADC_WIDTH-1:0]  p_hi_q, p_lo_q, pd_q, best_adc_q, adc_code,
    input logic                  locked, locked_q, rail_err_q, sweep_err_q, en_q,
    input logic [15:0]           thresh_q, minpow_q, settle_q,
    input logic [7:0]            dither_q, sweep_q,
    input logic                  psel, penable, pwrite, pready,
    input logic [ADDR_WIDTH-1:0] paddr,
    input logic [DATA_WIDTH-1:0] pwdata
);
```

All checks `disable iff (!rst_n)`:

1. **`p_locked_port`** : `locked == locked_q`.
2. **`p_dac_never_wraps`** : outside the three legitimately large transitions — a fresh
   start (`dac_q ← 0` on the `en_q` rising edge), the sweep→lock handoff
   (`dac_q ← best_code_q`), and `S_UPDATE → S_HI_WAIT` (which properly moves the *drive*
   by `2·dither_eff`) — `dac_code` never jumps by more than
   `max(2·dither_eff, sweep_eff)` in one clock. Targets the rail wraparound (`0 → DAC_MAX` or the reverse), which is
   the classic integrator-windup signature.

   > An earlier revision bounded every jump by `max(dither_eff, sweep_eff)`. That is
   > unsatisfiable by *any* correct implementation — the three transitions above are
   > all legal and all larger. Corrected after both the RTL and DV implementations
   > independently reported it.
3. **`p_no_lock_without_power`** — the false-lock guard, in **two parts**. A single
   `locked_q |-> pd_q >= minpow_q` is wrong: the probes for iteration *n+1* are
   re-sampled before `locked_q` can respond to them, so that form fires on every
   legitimate lock loss — an event §5's own cover list asks to observe. Instead:
   - **3a** — at the `S_UPDATE` that raises `locked_q`, `p_hi_q`, `p_lo_q` **and**
     `pd_q` were all `>= minpow_q`. (Including `pd_q` is stricter than the lock rule of
     §3.4 strictly requires, and is only sound because `pd_q` tracks every sample state
     per §2 — but it makes the guard checkable directly against the software-visible
     register.);
   - **3b** — an `S_UPDATE` that observes either probe below `minpow_q` must clear
     `locked_q` on the next clock.
4. **`p_rail_sticky`** / **`p_sweep_err_sticky`** : once set and absent a W1C to that
   bit this cycle, the flag remains set next cycle.
5. **`p_idle_when_disabled`** : `!en_q |=> state_q == S_IDLE`.
6. **`p_probe_hi_ge_centre`** : in `S_HI_WAIT`/`S_HI_SAMP`, `dac_code >= dac_q`;
   symmetrically `dac_code <= dac_q` in the `S_LO_*` states. Catches a swapped probe
   polarity, which inverts the loop into positive feedback.
7. **`p_settle_honoured`** : the FSM never leaves a `*_WAIT` state before `settle_q`
   clocks have elapsed in it.

Checks 8–12 are a **superset** of the original list, added during implementation
because the structure made them cheap and they pin down the loop's core invariants:

8. **`p_no_lock_when_dark`** : `locked_q` never rises while the ring is dark.
9. **`p_pd_captures_adc`** : every sample state loads `pd_q` from `adc_code`.
10. **`p_move_toward_bright`** : `dac_q` moves toward whichever probe read brighter —
    the loop-polarity check. An inverted comparison here turns the controller into
    positive feedback that runs to a rail, and is the single most damaging bug the
    block can have.
11. **`p_best_monotonic`** : `best_adc_q` never decreases within one sweep.
12. **`p_best_code_visited`** : the code the sweep hands to the fine loop equals the
    *combinational next* best code at the completing sample — catches the §3.3
    off-by-one. It must constrain the **handoff clock**; a property that merely bounds
    `best_code_q <= dac_q` during the sweep still passes against the buggy registered
    handoff and is therefore worthless for this purpose. The weaker within-sweep bound
    is retained separately as `p_best_code_not_ahead`.

Checks 13–16 close gaps found in review:

13. **`p_rail_hw_set_wins`** / 14. **`p_sweep_err_hw_set_wins`** : in a same-clock
    HW-set vs W1C race the flag **remains set** (§3.5). The sticky properties (4) alone
    do *not* cover this — their antecedents exclude the W1C cycle, so they go vacuous
    in precisely the race they appear to guard. A cover point is not a substitute: it
    cannot fail.
15. **`p_locked_only_from_update`** : `locked_q` only ever changes out of `S_UPDATE`.
16. Elaboration guards (not SVA, but same intent): `LOCK_N >= 1` (else `LOCK_CNT_W`
    degenerates to a zero-width vector), `DAC_WIDTH`/`ADC_WIDTH` within `DATA_WIDTH`,
    and a check that the *connected interface's* widths match — the register decode
    part-selects assume a 32-bit `prdata`, which the module parameter does not
    guarantee.

Cover: `locked` rising; `rail_err_q` rising; `sweep_err_q` rising; a lock that is lost
after having been acquired (`$fell(locked_q)` having previously risen); and the
W1C-vs-HW-set race on `RAIL_ERR`.

Detecting a legal W1C: a completing write (`psel && penable && pready && pwrite`) to
`STATUS` (`paddr == 'h10`) whose `pwdata[i]` is 1.

---

## 6. Verification strategy (informative)

- **VIP reuse:** the APB side reuses `common/apb_vip` unchanged — agent, adapter,
  coverage, `apb_protocol_checker`. The DV env mirrors `ip/apb_gpio/dv`.
- **New surface vs. GPIO/timer:** a **closed analog loop**. The DUT's input depends on
  its own output through a continuous-valued model, so there is no stimulus sequence
  that can be pre-computed — the interesting stimulus is the *physics*, randomized per
  test via the ring configuration object.
- **RAL:** `CTRL`/`STEP`/`SETTLE`/`LOCK_CFG` are RW; `DAC`/`PD` are RO+volatile;
  `STATUS` is per-field mixed. Exclude `STATUS`, `DAC`, `PD` from bit-bash
  (`NO_REG_BIT_BASH_TEST`) — all three are hardware-updated.

---

## 7. The optical model (normative for `dv/optics/`)

### 7.1 Units

Everything is expressed in **DAC-code space** rather than nm/pm. `res_code` is the
thermal state — in equivalent DAC codes — at which the ring resonance coincides with
the laser line. This removes an entire class of unit-conversion confusion from the
model without losing any behaviour the controller can observe. Time is in **clock
cycles**, not seconds (see §7.3).

### 7.2 Equations

Evaluated once per `posedge clk`:

```
temp  ← temp + (real'(dac_code) - temp) / tau_cycles        // 1st-order thermal lag
d     = temp - res_code                                     // detuning, DAC codes
trans = 1.0 / (1.0 + (2.0*d / fwhm_code)**2)                // Lorentzian, 1.0 on resonance
adc_r = p_peak_lsb * trans + noise                          // photodiode → ADC
adc_code = clamp(round(adc_r), 0, 2**ADC_WIDTH - 1)
```

- `trans` is `1.0` at `d = 0` and `0.5` at `|d| = fwhm_code/2` — a correct Lorentzian
  lineshape, which is what a single ring actually produces at its drop port.
- `noise` is uniform in `±noise_lsb`, drawn with `$urandom_range` so runs reproduce from
  the seed. The draw stays in SystemVerilog for **both** model backends (§7.7) — the C
  backend receives the already-drawn sample rather than generating its own, so seed
  reproducibility is a property of the environment, not of the backend in use.
- Only **one** resonance is modelled. Real rings have a comb of them spaced by the
  free spectral range, and locking to the wrong comb line is a genuine failure mode —
  it is deliberately **out of scope for v1.0** and noted in §8.

### 7.3 Time scaling (important, and state it in the README)

A real ring's thermal time constant is **microseconds to milliseconds**; at a 100 MHz
clock a faithful `tau` would be 10⁵–10⁶ cycles and a single lock acquisition would not
finish inside any reasonable simulation. `tau_cycles` is therefore **scaled down** to
tens of cycles.

This is sound because the controller cannot observe `tau` in absolute time — it only
ever observes the **ratio `settle_q / tau_cycles`**, i.e. whether it waited long enough
for the ring to reach its new temperature before sampling. Preserving that ratio
preserves every bug the loop can have. Tests must sweep the ratio, not a fixed `tau`.

### 7.4 Configuration and observability

The model is a module driven through a `ring_if` interface carrying the DUT-facing
signals **and** the physical parameters, which the DV environment randomizes per test:

| Field           | Type   | Meaning                                            |
|-----------------|--------|----------------------------------------------------|
| `res_code`      | `real` | Thermal state (in DAC codes) that aligns the ring   |
| `fwhm_code`     | `real` | Resonance linewidth in DAC codes                    |
| `tau_cycles`    | `real` | Thermal time constant in clock cycles               |
| `p_peak_lsb`    | `real` | ADC reading at perfect alignment                    |
| `noise_lsb`     | `real` | Uniform ADC noise amplitude                         |
| `laser_on`      | `bit`  | `0` forces `trans` to 0 — models a dark fibre       |
| `detune_code`   | `real` | **Output**: live `d`, for the scoreboard            |
| `temp_code`     | `real` | **Output**: live `temp`, for debug/waveforms        |

Exporting `detune_code` is the point of the whole exercise: it lets the scoreboard
check *"the loop locked to the actual resonance"* directly, which is unobservable from
the DUT's pins alone. Probing a behavioural model's internal state for checking is
standard practice in mixed-signal DV.

### 7.5 Required checks (scoreboard)

1. **Acquisition** — with `laser_on` and a reachable `res_code`, `locked` rises within
   a deadline derived from the programmed sweep and settle times.
2. **Accuracy** — once `locked`, `|detune_code| <= fwhm_code/2`. The loop must land on
   the resonance, not merely stop moving.
3. **Stability** — once `locked`, the observed span of `dac_code` over a long window
   stays within `6·dither_eff` (`±2·dither_eff` of centre wander plus the `±dither_eff`
   probe excursion): no limit cycle, no slow walk-off. Stated on `dac_code` because
   `dac_q` is an internal signal — the check must hold at the pins.
4. **No false lock** — with `laser_on = 0`, `locked` must **never** rise, and
   `SWEEP_ERR` must be set instead.
5. **Rail** — with `res_code` placed outside the DAC range, `RAIL_ERR` is set and
   `dac_q` saturates without wrapping.

**Every negative verdict carries a liveness requirement.** Checks 4 and the no-lock
half of this list assert that something did *not* happen — and a verdict of that shape
is passed by a DUT that does nothing whatsoever: `locked` tied low, an FSM that never
leaves `S_IDLE`, a dead photodiode, a `dac_code` stuck at 0. Such a test proves nothing
while reporting success, which is worse than having no test. Each negative check must
therefore also demand **positive evidence that the loop ran**: `CTRL.EN` observed
rising, `STATUS.ACTIVE` read high, `dac_code` spanning a substantial fraction of the
range, and — on a lit ring — a sample above `MINPOW` with a non-zero `PD` readback.
Absent evidence is an error, never a quiet pass. The same reasoning applies on the
positive side: a stability check only means something if the lock was actually *held*.

### 7.6 Required coverage

- `settle_q / tau_cycles` ratio, binned `{<1, 1–2, 2–4, >4}` — **crossed with lock
  outcome**. This cross is the headline result: it shows the loop fails to acquire
  when it samples the photodiode before the ring has thermally settled, which is the
  archetypal photonic control bug.
- Initial detuning sign and magnitude (`res_code` low / mid / high in the DAC range).
- `fwhm_code` binned narrow / medium / wide (a high-Q ring is harder to find).
- `dither_eff` relative to `fwhm_code` (too large a dither cannot resolve the peak).
- Outcome bins: locked, sweep-error, rail-error, lost-lock.

### 7.7 Model backends (SystemVerilog and DPI-C)

The model specified above has **two interchangeable implementations**. Which one runs is
a build- and run-time choice; it is not a change to this specification. **§7.2 remains
the single normative statement of the maths** — every backend implements exactly those
equations, in that order, on IEEE-754 doubles (a SystemVerilog `real` *is* a double), and
the equations are not restated anywhere else.

| `ring_if.model_mode` | What evaluates §7.2 |
|----------------------|---------------------|
| `RING_MODEL_SV` (0)      | the SystemVerilog model in `dv/optics/ring_model.sv` — **the default**, and the only backend that exists unless the build defines `RING_DPI` |
| `RING_MODEL_DPI` (1)     | a C model called over **DPI-C** (`common/dpi`); the SV branch is skipped and the loop closes through C |
| `RING_MODEL_COMPARE` (2) | **both**, in lockstep on identical inputs, checked against each other every clock |

**Why a C backend is normative-worthy at all.** In a real photonic flow the device model
is owned by the photonics/process team and is delivered as C (or as measured spectra
behind a C interface), because the same model must also feed circuit-simulator flows,
characterisation scripts and silicon correlation. Re-implementing it in SystemVerilog
forks the golden model. This section therefore fixes what a C backend *must* satisfy so
that swapping it in is a linkage decision rather than a change of physics.

Requirements on any non-SV backend:

1. **Identical operations in identical order.** The quantized `adc_code` MUST match the
   SystemVerilog model **exactly**, and the pre-quantization reals (`temp`, `d`) MUST
   agree to within `1e-9 + 1e-12·|ref|` — a tolerance sized only to absorb host-FPU
   excess precision, not to accommodate a re-derived expression. In particular the
   thermal lag is evaluated **before** the Lorentzian in the same call, so the `adc_code`
   returned reflects the `temp` computed on that clock; reordering shifts the loop's phase
   by one cycle and silently corrupts the `settle_q / tau_cycles` ratio §7.6 is built on.
2. **Degenerate parameters are clamped, not rejected**, with the same rule the SV model
   uses (`tau_cycles < 1.0 → 1.0`, `fwhm_code < 1.0 → 1.0`). The SV caller clamps before
   the call, so both backends are always given the same values.
3. **Randomness stays on the SystemVerilog side.** The `noise` term of §7.2 MUST be drawn
   in SystemVerilog with `$urandom_range` and *passed into* the backend, which adds it
   verbatim and MUST NOT call any RNG of its own. A C-side generator is invisible to
   `-sv_seed` / `+ntb_random_seed`, so a failing regression could not be replayed from its
   seed — the one property this environment cannot give up. Exactly one draw happens per
   post-reset clock in **every** backend, so the RNG stream does not depend on which model
   is running, and a COMPARE run feeds both models the same sample (two models given
   different noise disagree for a reason that has nothing to do with either being wrong).
4. **Events come last, and the crossing event is mandatory.** A backend MUST report a
   resonance crossing through the exported callback, and MUST commit its state and its
   output arguments *before* raising it, because the callback runs arbitrary
   SystemVerilog. The crossing event is required rather than optional because it is the
   only cheap evidence that a `context` import resolved its scope and that the exported
   SystemVerilog function was actually reachable — a backend that silently drops every
   callback is otherwise indistinguishable from a correct one until something depends on
   an event. The ADC-clip event travels the same channel but is **conditional**: a run
   whose peak never reaches `adc_max` legitimately never clips, so its absence is
   informational, not a failure.

**`RING_MODEL_COMPARE` is the equivalence check** — the acceptance criterion for any
port of this model. It runs both backends on the same inputs every clock and reports the
first disagreements in full (cycle, all inputs, both sets of outputs) and counts the rest.
The SV model drives the DUT's loop while the C model is measured against it, so a wrong C
model shows up as a localized stream of equivalence errors rather than as a garbage
acquisition. A COMPARE run that compared no cycles, or that raised no
resonance-crossing callback on stimulus that provably crosses resonance, MUST be treated
as a failure, not as a pass. Absence of a *clip* callback is a failure only on stimulus
that provably clips (per item 4).

**The whole DPI layer is optional and MUST remain so.** Every `import "DPI-C"` /
`export "DPI-C"` declaration lives behind `` `ifdef RING_DPI ``; with the define absent
the environment has no reference to any C symbol and behaves exactly as it did before the
layer existed, because the reference runs for this block happen on a browser-hosted
simulator that cannot compile user C. Requesting backend 1 or 2 in a build without the
define MUST be a fatal error naming the missing define — never a silent fall-back to
`RING_MODEL_SV`, which would let an equivalence run pass having never called C.

---

## 8. Out of scope for v1.0

Deliberate omissions, listed so the boundary is a design decision and not an oversight:
free spectral range / multi-resonance comb and wrong-peak lock, thermal crosstalk
between adjacent rings, laser wavelength drift and aging, multi-channel WDM
arbitration, PID control (v1.0 is fixed-step gradient ascent), and any
`real`-valued optical *phase* modelling. Each is a natural v2 increment.
