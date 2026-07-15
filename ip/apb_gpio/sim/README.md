# apb_gpio — UVM verification environment

Full UVM env for the `apb_gpio` IP: RAL, a cycle-exact reference-model
scoreboard, a second (ACTIVE) pin agent that drives `gpio_in` and observes
`gpio_out`/`gpio_oe`/`irq`, functional coverage, a virtual-sequence layer, bound
SVA, and a per-vseq test library. Standard UVM-1.2 / IEEE 1800.2. Mirrors the
`apb_timer` env structure (`s/timer/gpio/`) and reuses `common/apb_vip`
unchanged.

## What is here

```
ip/apb_gpio/
  rtl/apb_gpio.sv               DUT (owned by the RTL agent; do not modify here)
  rtl/apb_gpio_sva.sv           gpio SVA (bound onto the DUT)
  dv/apb_gpio_reg_block.svh     RAL: DATA_OUT/DATA_IN(RO)/DIR/INT_STATUS(W1C)/INT_EN
  dv/apb_gpio_env_cfg.svh       env config object
  dv/apb_gpio_ref_model.svh     cycle-exact predictor (+ evt item, 2-FF sync model)
  dv/apb_gpio_scoreboard.svh    APB + PIN paired-fifo scoreboard (exact compares)
  dv/apb_gpio_coverage.svh      gpio functional coverage
  dv/apb_gpio_env.svh           env (agents + RAL predictor + scb + cov)
  dv/pin/gpio_if.sv             pin interface (drives gpio_in, observes out/oe/irq)
  dv/pin/gpio_item.svh          pin stimulus + observation transactions
  dv/pin/gpio_driver.svh        pin driver (masked set/clear/toggle/drive)
  dv/pin/gpio_monitor.svh       pin monitor (samples per clock, emits on change)
  dv/pin/gpio_agent.svh         ACTIVE pin agent
  dv/seq/apb_gpio_vseq_lib.svh  virtual sequences
  dv/test/apb_gpio_test_lib.svh tests (one per vseq)
  dv/apb_gpio_pkg.sv            DV package (includes all dv .svh)
  tb/apb_gpio_tb_top.sv         tb top (clk/rst, ifs, DUT, binds, run_test)
  sim/run.f  sim/Makefile  sim/README.md
common/apb_vip/                 reused APB VIP (do not modify)
```

## Compile order (see `run.f`)

Interfaces compile at `$unit` **before** the packages that use their virtual-
interface types:

1. `common/apb_vip/apb_if.sv`, `ip/apb_gpio/dv/pin/gpio_if.sv`
2. `common/apb_vip/apb_vip_pkg.sv`  then  `ip/apb_gpio/dv/apb_gpio_pkg.sv`
3. `ip/apb_gpio/rtl/apb_gpio.sv`
4. `common/apb_vip/apb_protocol_checker.sv`, `ip/apb_gpio/rtl/apb_gpio_sva.sv`
   (plain-SVA modules, `bind`-ed in the tb top)
5. `ip/apb_gpio/tb/apb_gpio_tb_top.sv`

`+incdir` lines in `run.f` point at every directory holding a `.svh`.

Default widths (ADDR_WIDTH=8, DATA_WIDTH=32 = NPINS): the standalone build needs
**no** `+define+APB_ADDR_W`.

## Run locally

The Makefile `cd`s to the repo root (so `run.f`'s repo-root-relative paths
resolve) and requires UVM-1.2 from the tool. Pick a test with `TEST=` and a
seed with `SEED=`.

```
make -C ip/apb_gpio/sim questa TEST=apb_gpio_interrupt_test SEED=3
make -C ip/apb_gpio/sim vcs    TEST=apb_gpio_input_capture_test
make -C ip/apb_gpio/sim xrun   TEST=apb_gpio_reg_test
make -C ip/apb_gpio/sim regress          # all tests x several seeds (Questa)
```

Tests: `apb_gpio_smoke_test`, `apb_gpio_output_drive_test`,
`apb_gpio_input_capture_test`, `apb_gpio_interrupt_test`, `apb_gpio_w1c_test`,
`apb_gpio_error_test`, `apb_gpio_reg_test`, `apb_gpio_rand_test`.

## Run on EDA Playground

- Language: **SystemVerilog / UVM**, UVM version **1.2**.
- Tool: Questa / VCS / Xcelium (any).
- Enable your simulator's **SVA** and **coverage** if you want the bound
  properties and covergroups reported.
- Run/plusargs field: `+UVM_TESTNAME=apb_gpio_interrupt_test` (or any test above).

Panes (EDA Playground has no `run.f`; paste files respecting the order above —
the site compiles the *Design* pane first, then *Testbench*):

- **Design** pane (RTL + interfaces + plain SVA; these are `$unit`/RTL):
  `apb_if.sv`, `gpio_if.sv`, `apb_gpio.sv`,
  `apb_protocol_checker.sv`, `apb_gpio_sva.sv`.
- **Testbench** pane (packages + tb, plus the `.svh` includes reachable via the
  include path): `apb_vip_pkg.sv` and its `.svh` files, `apb_gpio_pkg.sv` and
  all `dv/**/*.svh`, and `apb_gpio_tb_top.sv` last. Make sure the top module
  `apb_gpio_tb_top` is the elaboration top.

Note: the `bind` statements live in `apb_gpio_tb_top.sv`; the two SVA modules
must be compiled (Design pane) so the binds resolve.

## Design notes

- **RAL prediction is EXPLICIT**: a `uvm_reg_predictor#(apb_seq_item)` is fed by
  the APB monitor; `default_map.set_auto_predict(0)`. `DATA_IN` and `INT_STATUS`
  are volatile (HW-updated) — the mirror may desync on HW changes; the true
  check lives in the reference-model scoreboard, not the mirror. Both are marked
  `NO_REG_BIT_BASH_TEST`.
- **Reference model** shadows the DUT state and steps once per posedge with the
  DUT's exact next-state equations, observing BOTH the APB bus and the external
  pins through the same preponed sampling the monitors use. It models the 2-FF
  input synchronizer (shadow flops `g_meta`/`g_sync`) and detects the rising edge
  **combinationally** from the two stages — `rise = g_meta & ~g_sync`, exactly as
  the RTL does (`din_meta & ~din_sync`), with no extra history flop — so `DATA_IN`
  readback and the rising-edge `INT_STATUS` set line up with the DUT bit- and
  cycle-exactly. It emits expected APB responses, expected pin outputs, and gpio
  events. Pairing is in-order via `uvm_tlm_analysis_fifo`s.
- **Tolerances**: none. Every APB read (including the volatile `DATA_IN`
  synchronizer readback) and every pin output (`gpio_out`/`gpio_oe`/`irq`) is
  compared exactly, at an exact posedge cycle stamp — the same tightened
  discipline as the timer scoreboard.
