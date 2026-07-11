// -----------------------------------------------------------------------------
// apb_subsystem_reg_block.svh : hierarchical UVM RAL model for apb_subsystem.
//
//   The whole point is REUSE: the apb_timer IP's reg block (apb_timer_reg_block)
//   is instantiated TWICE as sub-blocks, plus a 64-word memory region:
//
//     +-----------------------------------------------------------------+
//     | apb_subsystem_reg_block   (root, default_map base 0x000)         |
//     |   timer0 : apb_timer_reg_block  submap @ 0x000                   |
//     |   timer1 : apb_timer_reg_block  submap @ 0x100                   |
//     |   mem    : uvm_mem (64 x 32b)   @ 0x200                          |
//     +-----------------------------------------------------------------+
//
//   Each apb_timer_reg_block.build() builds + lock_model()s ITSELF (it is a
//   child here, so its lock only locks its own regs, not the address map). The
//   root add_submap()s each timer's default_map and then lock_model()s the whole
//   tree - Xinit_address_mapX() flattens every sub-register into the ROOT map at
//   its GLOBAL offset, so a single uvm_reg_predictor on default_map resolves
//   timer0/timer1 registers at 0x0nn / 0x1nn. Front-door bus ops always use the
//   ROOT map's sequencer+adapter (set once in the env), so hierarchical access
//   "just works" through the reused apb_reg_adapter over the top active agent.
//
//   default_map : base 0x000, 4 bytes/word, little-endian, byte-addressed.
// -----------------------------------------------------------------------------
`ifndef APB_SUBSYSTEM_REG_BLOCK_SVH
`define APB_SUBSYSTEM_REG_BLOCK_SVH

class apb_subsystem_reg_block extends uvm_reg_block;
  `uvm_object_utils(apb_subsystem_reg_block)

  // Two reused timer register blocks + a memory region.
  rand apb_timer_reg_block timer0;   // page 0x0
  rand apb_timer_reg_block timer1;   // page 0x1
       uvm_mem             mem;       // page 0x2 (64 words)

  uvm_reg_map default_map;

  // Subsystem page bases (byte offsets in the top map).
  localparam uvm_reg_addr_t TIMER0_BASE = 12'h000;
  localparam uvm_reg_addr_t TIMER1_BASE = 12'h100;
  localparam uvm_reg_addr_t MEM_BASE    = 12'h200;
  localparam int            MEM_WORDS    = 64;

  function new(string name = "apb_subsystem_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    // ---- root address map (base 0, 4 bytes/word, little-endian) ----
    default_map = create_map("default_map", 12'h000, 4, UVM_LITTLE_ENDIAN, 1);

    // ---- timer0 : reused apb_timer_reg_block at page 0x000 ----
    timer0 = apb_timer_reg_block::type_id::create("timer0");
    timer0.configure(this);   // register as a child block of this root
    timer0.build();           // builds regs + its own default_map, locks its regs
    default_map.add_submap(timer0.default_map, TIMER0_BASE);

    // ---- timer1 : the SAME class reused at page 0x100 ----
    timer1 = apb_timer_reg_block::type_id::create("timer1");
    timer1.configure(this);
    timer1.build();
    default_map.add_submap(timer1.default_map, TIMER1_BASE);

    // ---- mem : 64 x 32-bit RW memory at page 0x200 ----
    // uvm_mem takes ctor args (size,n_bits) so it is built via new(), then
    // configured into this block and added to the root map.
    mem = new("mem", MEM_WORDS, 32, "RW", UVM_NO_COVERAGE);
    mem.configure(this, "");
    default_map.add_mem(mem, MEM_BASE, "RW");

    // ---- lock the whole tree : flattens submap register addresses ----
    lock_model();
  endfunction

endclass

`endif // APB_SUBSYSTEM_REG_BLOCK_SVH
