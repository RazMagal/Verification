// -----------------------------------------------------------------------------
// apb_subsystem_scoreboard.svh : subsystem-level self-checker (upstream view).
//
//   Fed by the TOP active agent's monitor (one apb_seq_item per completed
//   upstream beat). It checks the two things the per-timer ref-model scoreboards
//   do NOT: the fabric decode and the memory contents.
//
//     * DECODE / pslverr :
//         page 0x3..0xF (unmapped) -> MUST return pslverr=1, rdata=0 (fabric).
//         page 0x2 (mem)           -> MUST NOT error (mem never asserts pslverr).
//         page 0x0/0x1 (timers)    -> legal reg offset {0,4,8,C,10} -> no error;
//                                     any other offset -> timer pslverr=1, rdata0
//                                     (verifies the fabric does not spuriously
//                                      error mapped pages and forwards slave
//                                      errors faithfully).
//     * MEMORY shadow : a 64-word reference store. Writes (no error) update the
//         shadow; reads (no error) of a PREVIOUSLY-WRITTEN word are compared to
//         the shadow (never-written words are undefined per the mem spec and are
//         skipped).
//
//   check_phase reports counts and guards against zero activity.
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_SCOREBOARD_SVH
`define APB_SUBSYSTEM_SCOREBOARD_SVH

class apb_subsystem_scoreboard extends uvm_subscriber #(apb_seq_item);
  `uvm_component_utils(apb_subsystem_scoreboard)

  // ---- shadow memory for the mem page (0x200) ----
  localparam int MEM_WORDS = 64;
  bit [31:0] shadow  [MEM_WORDS];
  bit        written [MEM_WORDS];

  // ---- page ids (paddr[11:8]) ----
  localparam bit [3:0] PAGE_T0  = 4'h0;
  localparam bit [3:0] PAGE_T1  = 4'h1;
  localparam bit [3:0] PAGE_MEM = 4'h2;

  // ---- counters ----
  int unsigned n_total, n_decode_pass, n_decode_fail;
  int unsigned n_mem_checks, n_mem_pass, n_mem_fail;

  function new(string name = "apb_subsystem_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // A legal apb_timer register byte offset (spec 2).
  function bit timer_off_legal(bit [7:0] off);
    return (off inside {8'h00, 8'h04, 8'h08, 8'h0C, 8'h10});
  endfunction

  virtual function void write(apb_seq_item t);
    bit [3:0] page = t.addr[11:8];
    bit [7:0] off  = t.addr[7:0];
    n_total++;
    case (page)
      PAGE_MEM:          check_mem(t, off);
      PAGE_T0, PAGE_T1:  check_timer(t, off);
      default:           check_unmapped(t);   // 0x3..0xF
    endcase
  endfunction

  // ---- mem page : never errors; shadow read/write check ----
  function void check_mem(apb_seq_item t, bit [7:0] off);
    int unsigned widx = off[7:2];    // word index within the 256B page
    if (t.slverr !== 1'b0) begin
      n_decode_fail++;
      `uvm_error("SCB_SS_MEM_ERR", $sformatf(
                 "mem access @0x%03h unexpectedly asserted pslverr", t.addr))
      return;
    end
    n_decode_pass++;
    if (t.dir == APB_WRITE) begin
      shadow[widx]  = t.wdata;
      written[widx] = 1'b1;
      `uvm_info("SCB_SS_MEM_WR", $sformatf("mem[%0d] <= 0x%08h", widx, t.wdata),
                UVM_HIGH)
    end
    else begin // read
      if (written[widx]) begin
        n_mem_checks++;
        if (t.rdata !== shadow[widx]) begin
          n_mem_fail++;
          `uvm_error("SCB_SS_MEM_RD", $sformatf(
                     "mem[%0d] read 0x%08h expected 0x%08h", widx, t.rdata,
                     shadow[widx]))
        end
        else begin
          n_mem_pass++;
          `uvm_info("SCB_SS_MEM_RD", $sformatf("mem[%0d] == 0x%08h OK", widx,
                    t.rdata), UVM_HIGH)
        end
      end
    end
  endfunction

  // ---- timer pages : legal offset -> no error; illegal -> timer pslverr ----
  function void check_timer(apb_seq_item t, bit [7:0] off);
    bit exp_err = ~timer_off_legal(off);
    if (t.slverr !== exp_err) begin
      n_decode_fail++;
      `uvm_error("SCB_SS_TMR_DEC", $sformatf(
                 "timer access @0x%03h : pslverr exp=%0b act=%0b (off=0x%02h)",
                 t.addr, exp_err, t.slverr, off))
    end
    else begin
      n_decode_pass++;
    end
    // On an errored read the slave must return 0.
    if (exp_err && (t.dir == APB_READ) && (t.rdata !== 32'h0)) begin
      n_decode_fail++;
      `uvm_error("SCB_SS_TMR_RD0", $sformatf(
                 "errored timer read @0x%03h returned 0x%08h (exp 0)", t.addr,
                 t.rdata))
    end
  endfunction

  // ---- unmapped pages : fabric self-responds pslverr=1, rdata=0 ----
  function void check_unmapped(apb_seq_item t);
    if (t.slverr !== 1'b1) begin
      n_decode_fail++;
      `uvm_error("SCB_SS_DEC_NOERR", $sformatf(
                 "unmapped access @0x%03h did NOT assert pslverr", t.addr))
    end
    else begin
      n_decode_pass++;
    end
    if ((t.dir == APB_READ) && (t.rdata !== 32'h0)) begin
      n_decode_fail++;
      `uvm_error("SCB_SS_DEC_RD0", $sformatf(
                 "unmapped read @0x%03h returned 0x%08h (exp 0)", t.addr, t.rdata))
    end
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    `uvm_info("SCB_SS_REPORT", $sformatf(
      "upstream=%0d | decode pass=%0d fail=%0d | mem checks=%0d pass=%0d fail=%0d",
      n_total, n_decode_pass, n_decode_fail, n_mem_checks, n_mem_pass, n_mem_fail),
      UVM_LOW)

    if (n_total == 0)
      `uvm_error("SCB_SS_NO_ACTIVITY",
                 "subsystem scoreboard saw ZERO upstream transactions")
    if ((n_decode_fail != 0) || (n_mem_fail != 0))
      `uvm_error("SCB_SS_FAIL", $sformatf(
                 "subsystem scoreboard mismatches: decode=%0d mem=%0d",
                 n_decode_fail, n_mem_fail))
  endfunction

endclass

`endif // APB_SUBSYSTEM_SCOREBOARD_SVH
