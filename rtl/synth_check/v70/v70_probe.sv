module v70_probe (input clk, input ce, input rst, input fast_ifetch,
  output bus_req, output bus_we, output [31:0] bus_addr, output [1:0] bus_size,
  output [31:0] bus_wdata, input [31:0] bus_rdata, input bus_ack,
  input irq_n, input [7:0] irq_vector, output irq_ack, input nmi_n);
s32_v60 #(.START_PC(32'hffff_fff0), .IS_V70(1'b1)) dut (
  .clk(clk), .ce(ce), .rst(rst), .fast_ifetch(fast_ifetch), .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
  .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_size(bus_size),
  .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
  .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(irq_ack), .nmi_n(nmi_n));
endmodule
