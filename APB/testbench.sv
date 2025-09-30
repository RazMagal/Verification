
`timescale 1ns/1ps;

`include "uvm_macros.svh"
`include "apb_tb_pkg.svh"
module tb_top;
  import uvm_pkg::*;
  import apb_tb_pkg::*;
  
  bit tb_clk;
  bit rst_n;
  
  always #5 tb_clk = ~tb_clk;
  initial begin
    rst_n = 0;
    #5 rst_n = 1;
  end
  
  apb_if #(
    .ADDR_WIDTH(ADDRESS_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) intf();
  
  assign intf.clk   = tb_clk;
  assign intf.rst_n = rst_n;
  
  apb_slave_better slave_inst (
    .apb(intf.slave)
   );
  apb_checker protocol_checker_inst(
    .intf(intf)
  );

  initial begin
    uvm_config_db#(virtual apb_if.m_drv_mp)::set(uvm_root::get(),"*","vif",intf.m_drv_mp);
    uvm_config_db#(virtual apb_if.m_mon_mp)::set(uvm_root::get(),"*","vif",intf.m_mon_mp);
    uvm_config_db#(virtual apb_if)::set(uvm_root::get(),"*","vif",intf);
    
    
    $dumpfile("dump.vcd"); $dumpvars; // to see waveform we need to "dump"
    run_test("apb_test"); // find this test class that extends uvm_test
  end
  
endmodule