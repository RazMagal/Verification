# apb_timer — UVM verification environment

Full UVM env for the `apb_timer` IP: RAL, a cycle-accurate reference-model
scoreboard, a second (passive) IRQ agent, functional coverage, a virtual-sequence
layer, bound SVA, and a per-vseq test library. Standard UVM-1.2 / IEEE 1800.2.

## What is here

```
ip/apb_timer/
  rtl/apb_timer.sv          DUT (do not modify)
  rtl/apb_timer_sva.sv      timer SVA (bound onto the DUT)
  dv/apb_timer_params.svh       width macros -> package parameters (included FIRST)
  dv/apb_timer_reg_block.svh    RAL: CTRL/LOAD/VALUE/STATUS(W1C)/PRESCALE
  dv/apb_timer_env_cfg.svh      env config object
  dv/apb_timer_ref_model.svh    tick-accurate predictor (+ evt item)
  dv/apb_timer_scoreboard.svh   APB + IRQ paired-fifo scoreboard
  dv/apb_timer_coverage.svh     timer functional coverage
  dv/apb_timer_env.svh          env (agents + RAL predictor + scb + cov)
  dv/irq/timer_irq_if.sv        passive irq interface
  dv/irq/timer_irq_item.svh     irq edge transaction
  dv/irq/timer_irq_monitor.svh  passive irq monitor
  dv/irq/timer_irq_agent.svh    passive irq agent
  dv/seq/apb_timer_vseq_lib.svh virtual sequences
  dv/test/apb_timer_test_lib.svh tests (one per vseq)
  dv/apb_timer_pkg.sv           DV package (includes all dv .svh)
  tb/apb_timer_tb_top.sv        tb top (clk/rst, ifs, DUT, binds, run_test)
  sim/run.f  sim/Makefile  sim/README.md
common/apb_vip/                 reused APB VIP (do not modify)
```

## Compile order (see `run.f`)

Interfaces compile at `$unit` **before** the packages that use their virtual-
interface types:

1. `common/apb_vip/apb_if.sv`, `ip/apb_timer/dv/irq/timer_irq_if.sv`
2. `common/apb_vip/apb_vip_pkg.sv`  then  `ip/apb_timer/dv/apb_timer_pkg.sv`
3. `ip/apb_timer/rtl/apb_timer.sv`
4. `common/apb_vip/apb_protocol_checker.sv`, `ip/apb_timer/rtl/apb_timer_sva.sv`
   (plain-SVA modules, `bind`-ed in the tb top)
5. `ip/apb_timer/tb/apb_timer_tb_top.sv`

`+incdir` lines in `run.f` point at every directory holding a `.svh`.

Widths are stated **once**. `common/apb_vip/apb_width_defines.svh` holds the
guarded `` `APB_ADDR_W ``/`` `APB_DATA_W `` macros; `dv/apb_timer_params.svh`
derives `` `APB_TIMER_ADDR_W ``/`` `APB_TIMER_DATA_W `` from them (plus the IP's own
`` `APB_TIMER_PRESC_W ``) and turns them into package parameters. The RAL field
widths — including the **reserved** fields, which are `DATA_WIDTH - lsb`, never a
literal 29/31/24 — the reference model's shadow state, the coverage bins and the tb
top's DUT instance all read from those. `soc/apb_subsystem` reuses this RAL under
`+define+APB_ADDR_W=12`; the register geometry is address-width-independent, so it
elaborates identically there.

## Run locally

The Makefile `cd`s to the repo root (so `run.f`'s repo-root-relative paths
resolve) and requires UVM-1.2 from the tool. Pick a test with `TEST=` and a
seed with `SEED=`.

```
make -C ip/apb_timer/sim questa TEST=apb_timer_oneshot_test SEED=3
make -C ip/apb_timer/sim vcs    TEST=apb_timer_periodic_test
make -C ip/apb_timer/sim xrun   TEST=apb_timer_reg_test
make -C ip/apb_timer/sim regress          # all tests x several seeds (Questa)
```

Tests: `apb_timer_smoke_test`, `apb_timer_oneshot_test`,
`apb_timer_periodic_test`, `apb_timer_prescale_test`, `apb_timer_w1c_test`,
`apb_timer_irq_mask_test`, `apb_timer_error_test`, `apb_timer_reg_test`,
`apb_timer_rand_test`.

## Run on EDA Playground

- Language: **SystemVerilog / UVM**, UVM version **1.2**.
- Tool: **Aldec Riviera-PRO** — full UVM/SVA support and the only UVM-capable
  simulator on Playground that needs no account validation. Questa / VCS /
  Xcelium work too, but require a pre-approved institutional email.
- Enable your simulator's **SVA** and **coverage** if you want the bound
  properties and covergroups reported.
- Run/plusargs field: `+UVM_TESTNAME=apb_timer_oneshot_test` (or any test above).

Panes (EDA Playground has no `run.f`; paste files respecting the order above —
the site compiles the *Design* pane first, then *Testbench*):

- **Design** pane (RTL + interfaces + plain SVA; these are `$unit`/RTL):
  `apb_if.sv`, `timer_irq_if.sv`, `apb_timer.sv`,
  `apb_protocol_checker.sv`, `apb_timer_sva.sv`.
  `apb_if.sv` `` `include ``s `apb_width_defines.svh`, so that header must exist in
  the workspace (macros only — no declarations — so it can sit in either pane's
  file set).
- **Testbench** pane (packages + tb, plus the `.svh` includes reachable via the
  include path): `apb_vip_pkg.sv` and its `.svh` files, `apb_timer_pkg.sv` and
  all `dv/**/*.svh`, and `apb_timer_tb_top.sv` last. Make sure the top module
  `apb_timer_tb_top` is the elaboration top.

Note: the `bind` statements live in `apb_timer_tb_top.sv`; the two SVA modules
must be compiled (Design pane) so the binds resolve.

## Design notes

- **RAL prediction is EXPLICIT**: a `uvm_reg_predictor#(apb_seq_item)` is fed by
  the APB monitor; `default_map.set_auto_predict(0)`. `VALUE` and `STATUS.IRQ`
  are volatile (HW-updated) — the mirror may desync on HW changes; the true
  check lives in the reference-model scoreboard, not the mirror.
- **Reference model** shadows the DUT state and steps once per posedge with the
  DUT's exact next-state equations, observing the APB bus through
  `apb_if.m_mon_cb` (same preponed sampling as the monitor). It emits expected
  APB responses, expected IRQ edges, and timer events. Pairing is in-order via
  `uvm_tlm_analysis_fifo`s.
- **Tolerances**: APB reads are exact except `VALUE` (live counter) which is
  checked exact-preferred with a documented **±1** allowance for sampling skew.
  IRQ edge polarity/sequence are exact; the edge **cycle stamp** is checked
  within **±1**. One-shot EN-auto-clear, periodic re-assert, W1C and pslverr are
  checked exactly via the STATUS/CTRL read checks and the slverr comparisons.
