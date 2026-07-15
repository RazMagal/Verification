// -----------------------------------------------------------------------------
// gpio_driver.svh : drives the DUT's external inputs (gpio_in) through the
//   gpio_if.drv_cb clocking block. It keeps a shadow of the currently-driven
//   pin vector and mutates it per item (masked set / clear / toggle / drive),
//   then holds for `hold` clocks. gpio_in is forced to 0 out of reset so the
//   DUT synchronizer never sees X, and re-zeroed whenever reset asserts.
// -----------------------------------------------------------------------------
`ifndef GPIO_DRIVER_SVH
`define GPIO_DRIVER_SVH

class gpio_driver extends uvm_driver #(gpio_item);
  `uvm_component_utils(gpio_driver)

  virtual gpio_if               vif;
  bit [APB_DATA_WIDTH-1:0]      cur;   // shadow of the driven gpio_in

  function new(string name = "gpio_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual gpio_if)::get(this, "", "vif", vif))
      `uvm_fatal("GPIO_DRV_NOVIF", "virtual gpio_if 'vif' not set for driver")
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    cur = '0;
    // establish a known 0 on the pins before the first stimulus
    @(vif.drv_cb);
    vif.drv_cb.gpio_in <= cur;
    forever begin
      // Hold pins at 0 while in reset (do not consume items during reset).
      if (vif.rst_n !== 1'b1) begin
        cur = '0;
        vif.drv_cb.gpio_in <= cur;
        @(vif.drv_cb);
        continue;
      end
      seq_item_port.get_next_item(req);
      case (req.op)
        GPIO_DRIVE:  cur = (cur & ~req.mask) | (req.value & req.mask);
        GPIO_SET:    cur =  cur |  req.mask;
        GPIO_CLEAR:  cur =  cur & ~req.mask;
        GPIO_TOGGLE: cur =  cur ^  req.mask;
        default:     ;
      endcase
      @(vif.drv_cb);
      vif.drv_cb.gpio_in <= cur;
      repeat (req.hold) @(vif.drv_cb);
      `uvm_info("GPIO_DRV", $sformatf("%s -> gpio_in=0x%08h",
                req.convert2string(), cur), UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask

endclass

`endif // GPIO_DRIVER_SVH
