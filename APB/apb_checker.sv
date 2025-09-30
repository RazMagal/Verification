module apb_checker (apb_if intf);
  /*
  Protocol compliance assertions we put in the monitor:
  I use property because they offer reuse both in coverage and in Formal Verification (optional job pivot ^_^).
  coverage, assertions, property syntax is robust and I won't explain all here nor use all they hav to offer.
  */
  
  // synopsys translate_off
  property stable_signals_while_wait;
    @(posedge intf.clk)
      disable iff (!intf.rst_n)
      // ACCESS phase, keep steady until we get pready
      (intf.penable && !intf.pready) |-> (
        $stable(intf.paddr) &&
        $stable(intf.pwrite) &&
        $stable(intf.psel) &&
        $stable(intf.pwdata)
      );
  endproperty

  a_stable_signals: assert property (stable_signals_while_wait)
    else begin
      `uvm_error("APV_PROTOCOL", $sformatf("[%0t] APB violation: signals changed while in ACCESS phase waiting for pready. paddr cur=%0h prev=%0h; pwrite cur=%0b prev=%0b; psel cur=%0b prev=%0b; pwdata cur=%0h prev=%0h", $time, intf.paddr, $past(intf.paddr), intf.pwrite,  $past(intf.pwrite), intf.psel, $past(intf.psel), intf.pwdata, $past(intf.pwdata)));
    end

  // ACCESS phase, penable can't go low until we get pready
    property penable_stable_while_wait;
    @(posedge intf.clk)
      disable iff (!intf.rst_n)
      ($past(intf.penable) && !$past(intf.pready)) |-> intf.penable;
  endproperty

    a_penable: assert property (penable_stable_while_wait)
    else begin
      `uvm_error("APV_PROTOCOL", $sformatf("[%0t] APB violation: PENABLE changed while PREADY=0 - cur=%0b prev=%0b", $time, intf.penable, $past(intf.penable)));
    end

  // synopsys translate_on
endmodule
