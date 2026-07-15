# `apb_gpio` — Specification (verification contract)

A general-purpose parallel I/O peripheral on an APB3 slave port. This document is
the **single source of truth** shared by the RTL (`rtl/`) and the UVM DV
environment (`dv/`): the port list, register map, behaviour, and the **internal
signal names** the bound SVA / reference model rely on are all fixed here.

Style and conventions mirror [`../../apb_timer/docs/apb_timer_spec.md`](../../apb_timer/docs/apb_timer_spec.md).

---

## 1. Interface

```systemverilog
module apb_gpio #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32   // also the number of GPIO pins (NPINS)
) (
    apb_if.slave              apb,       // reuses common/apb_vip apb_if (slave modport)
    input  logic [DATA_WIDTH-1:0] gpio_in,   // external pin inputs
    output logic [DATA_WIDTH-1:0] gpio_out,  // pin output values (to pad)
    output logic [DATA_WIDTH-1:0] gpio_oe,   // per-pin output enable (to pad)
    output logic                  irq        // active-high level interrupt
);
```

- `NPINS = DATA_WIDTH` (32). This is a **GPIO core** that exposes `gpio_out` /
  `gpio_oe` / `gpio_in` to an external pad ring — there is no internal tri-state
  and **no internal loopback**: `gpio_in` reflects only the outside world.
- Clock/reset come from `apb.clk` / `apb.rst_n` (active-low, async assert,
  **synchronous de-assert**), same as `apb_timer`.
- APB is a single-cycle slave (combinational `pready = 1`), same protocol as the
  timer: SETUP → ACCESS, `pslverr` on illegal address.

---

## 2. Register map (byte offsets in `[0x00 .. 0xFF]`)

| Offset | Name         | Access | Reset | Description                                            |
|--------|--------------|--------|-------|--------------------------------------------------------|
| `0x00` | `DATA_OUT`   | RW     | 0     | Value driven onto `gpio_out` (all pins).               |
| `0x04` | `DATA_IN`    | RO     | 0     | Synchronized live sample of `gpio_in` (see §3.2).      |
| `0x08` | `DIR`        | RW     | 0     | Per-pin direction / output enable: `1`=output, `0`=input. |
| `0x0C` | `INT_STATUS` | RW1C   | 0     | Per-pin rising-edge-detected flag, sticky (see §3.3).  |
| `0x10` | `INT_EN`     | RW     | 0     | Per-pin interrupt enable.                              |

Any other offset in `[0x00 .. 0xFF]` → **illegal access** → `pslverr = 1`,
`rdata = 0`. A write to the RO `DATA_IN` register is **silently dropped**
(no `pslverr`, no effect), matching the timer's RO `VALUE` behaviour.

All registers are `DATA_WIDTH` bits wide; every bit position maps to pin index.

---

## 3. Behaviour

### 3.1 Output path
- `gpio_out = DATA_OUT` (registered value, all bits driven unconditionally).
- `gpio_oe  = DIR` (per pin; the external pad uses `gpio_oe[i]` to decide whether
  to drive `gpio_out[i]`).

### 3.2 Input path (synchronizer)
- `gpio_in` is passed through a **2-flop synchronizer** to `din_sync`.
- `DATA_IN` reads back `din_sync` (the synchronized value), never the raw pin.
- `din_sync` resets to 0.

### 3.3 Interrupt path (rising-edge detect, sticky, W1C)
- A **rising edge** on `din_sync[i]` (`0 → 1` between consecutive clocks) sets
  `INT_STATUS[i] = 1`. The flag is **sticky**: hardware only ever sets it; it is
  cleared solely by a write-1-to-clear to `INT_STATUS`.
- Edge detection is independent of `DIR` (it watches `din_sync`, i.e. the external
  input, for every pin). Software uses `INT_EN` to choose which flags matter.
- **HW-set-wins race:** if a rising edge and a W1C to the same bit land on the same
  clock, the bit stays set (HW set has priority), exactly like `apb_timer` STATUS.
- `irq = |(INT_STATUS & INT_EN)` — combinational, active-high.

### 3.4 Reset
- Active-low `apb.rst_n`, async assert / sync de-assert. All registers, `din_sync`,
  and `irq` reset to 0; `gpio_out`/`gpio_oe` follow their (reset) register values.

---

## 4. Internal signal names (fixed — for the bound SVA and reference model)

The RTL **must** use exactly these names so `apb_gpio_sva` can bind by name and the
DV reference model documentation stays valid:

| Signal      | Width           | Meaning                                   |
|-------------|-----------------|-------------------------------------------|
| `dout_q`    | `[DATA_WIDTH-1:0]` | `DATA_OUT` register                       |
| `dir_q`     | `[DATA_WIDTH-1:0]` | `DIR` register                            |
| `inten_q`   | `[DATA_WIDTH-1:0]` | `INT_EN` register                         |
| `intstat_q` | `[DATA_WIDTH-1:0]` | `INT_STATUS` register (sticky)            |
| `din_sync`  | `[DATA_WIDTH-1:0]` | 2-FF synchronized input (`DATA_IN` value) |

Plus the module outputs `gpio_out`, `gpio_oe`, `irq`.

---

## 5. Assertions (bindable `apb_gpio_sva`, plain SVA)

Bound onto `apb_gpio`; all checks disabled in reset (`disable iff (!rst_n)`):

1. **`p_oe_follows_dir`** : `gpio_oe == dir_q`.
2. **`p_out_follows_dout`** : `gpio_out == dout_q`.
3. **`p_irq_level`** : `irq == (|(intstat_q & inten_q))`.
4. **`p_intstat_sticky`** (per pin, `genvar`): if `intstat_q[i]` is set and there is
   no W1C to bit `i` this cycle, it stays set next cycle.

Cover: an `INT_STATUS` bit rising (`$rose` of any bit), `irq` rising, and the
W1C-vs-HW-set race (a W1C attempt on a bit that stays set).

Detecting a legal W1C for the sticky check: a completing write
(`psel && penable && pready && pwrite`) to `INT_STATUS` (`paddr == 'h0C`) whose
`pwdata[i]` is 1.

---

## 6. Verification notes (informative)

- **VIP reuse:** the APB side reuses `common/apb_vip` unchanged (agent, adapter,
  coverage, `apb_protocol_checker`). The DV env mirrors `ip/apb_timer/dv`.
- **New surface vs. the timer:** a bidirectional-style pin interface (`gpio_in`
  driven by DV, `gpio_out`/`gpio_oe`/`irq` observed), an input synchronizer, and
  edge-triggered interrupts — exercised by a small pin-stimulus agent analogous to
  `timer_irq_*`.
- **RAL:** `DATA_OUT`/`DIR`/`INT_EN` are RW, `DATA_IN` is RO, `INT_STATUS` is W1C.
  Exclude `INT_STATUS`/`DATA_IN` from bit-bash (`NO_REG_BIT_BASH_TEST`) as needed;
  `DATA_IN` mirrors external stimulus so it is a read-only/volatile field.
