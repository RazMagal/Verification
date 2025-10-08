// APB3 interface
interface apb_if #(parameter ADDR_WIDTH = 8, DATA_WIDTH = 32);
  logic                  clk;
  logic                  rst_n;
  logic [ADDR_WIDTH-1:0] paddr;
  logic                  pwrite;
  logic                  penable;
  logic                  psel;
  logic [DATA_WIDTH-1:0] pwdata;
  logic [DATA_WIDTH-1:0] prdata;
  logic                  pready;
  logic                  pslverr;

  // defining directions for APB3 slave 
  modport slave (
    input  clk, rst_n, paddr, pwrite, psel, penable, pwdata,
    output prdata, pready, pslverr
  );
  
  
  // Clocking block is ONLY for simulations, turn off synthesis for the block
  // synopsys: translate_off
  clocking m_drv_cb@(posedge clk);
    // keeping it simple, without skews
    // default input #1 output #0;
    input  prdata, pready, pslverr;
    output paddr, pwrite, psel, penable, pwdata;
  endclocking
  
  clocking m_mon_cb@(posedge clk);
    // default input #1 output #0;
    input  prdata, pready, pslverr, paddr, pwrite, psel, penable, pwdata;
  endclocking
  
  modport m_drv_mp (clocking m_drv_cb,   input rst_n);
  modport m_mon_mp (clocking m_mon_cb, input rst_n);
  // synopsys: translate_on
    
endinterface

/*
module apb_slave(
  apb_if.slave apb
);
  logic [31:0] mem [256];
  logic [1:0] apb_st;
  const logic [1:0] SETUP = 0;
  const logic [1:0] W_ENABLE = 1;
  const logic [1:0] R_ENABLE = 2;
  
  // SETUP -> ENABLE
  always @(negedge apb.rst_n or posedge apb.clk) begin
  if (apb.rst_n == 0) begin
    apb_st <= 0;
    apb.prdata <= 0;
  end
  else begin
    case (apb_st)
      SETUP : begin
        // clear the prdata
        apb.prdata <= 0;
        // Move to ENABLE when the psel is asserted
        if (apb.psel && !apb.penable) begin
          if (apb.pwrite) begin
            apb_st <= W_ENABLE;
          end
          else begin
            apb_st <= R_ENABLE;
          end
        end
      end
      W_ENABLE : begin
        // write pwdata to memory
        if (apb.psel && apb.penable && apb.pwrite) begin
          mem[apb.paddr] <= apb.pwdata;
        end
        // return to SETUP
        apb_st <= SETUP;
      end
      R_ENABLE : begin
        // read prdata from memory
        if (apb.psel && apb.penable && !apb.pwrite) begin
          apb.prdata <= mem[apb.paddr];
        end
        // return to SETUP
        apb_st <= SETUP;
      end
    endcase
  end
end
endmodule
 */
  
// APB3 Slave, notice it takes as input only the slave modport. It bundles all signals in the interface which is nicer for multi-interface dut's
module apb_slave_better #(
  parameter ADDR_WIDTH = 8,
  parameter DATA_WIDTH = 32
) (
  apb_if.slave apb
);
  // simple memory
  logic [DATA_WIDTH-1:0] mem [2**ADDR_WIDTH];

  // state encoding better for waveform debug
  typedef enum logic [1:0] {SETUP=0, W_ENABLE=1, R_ENABLE=2} apb_state_e;
  apb_state_e state;

  // main state machine
  always_ff @(posedge apb.clk or negedge apb.rst_n) begin
    if (!apb.rst_n) begin
      state     <= SETUP;
      apb.prdata <= '0;
      apb.pready <= 1'b0;
      apb.pslverr <= 1'b0;
    end else begin
      
      // $display("[%0t] Clk=%0d, State=%0d PSEL=%0b PENABLE=%0b PWRITE=%0b PADDR=%h PWDATA=%h PREADY=%0b", $time, apb.clk, state, apb.psel, apb.penable, apb.pwrite, apb.paddr, apb.pwdata, apb.pready);
      // defaults, last assignment for each var takes effect
      apb.pready  <= 1'b0;
      apb.pslverr <= 1'b0;
      apb.prdata  <= '0;
      
      case (state)
        SETUP: begin
          if (apb.psel && !apb.penable) begin 
            state <= apb.pwrite ? W_ENABLE : R_ENABLE;
          end
        end
        
        W_ENABLE: begin
          if (apb.psel && apb.penable && apb.pwrite) begin
            mem[apb.paddr] <= apb.pwdata;
            apb.pready     <= 1'b1;
            state          <= SETUP;
          end else begin
            apb.pready <= 1'b0; // hold wait-state
            state      <= W_ENABLE;
          end
        end
        
        R_ENABLE: begin
          if (apb.psel && apb.penable && !apb.pwrite) begin
            apb.prdata <= mem[apb.paddr];
            apb.pready <= 1'b1;
            state      <= SETUP;
          end
          else begin
            apb.pready <= 1'b0; // hold wait-state
            state      <= R_ENABLE;
          end
        end
      endcase
    end
  end
endmodule
    
