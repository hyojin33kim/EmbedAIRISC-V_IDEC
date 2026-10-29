// 주소와 데이터 단계를 분리해 NPU 제어 레지스터를 접근하는 AHB 검증 구동기이다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module ahb_master_bfm #(
  parameter int ADDR_W = 34
) (
  input logic clk, rst_n,
  output logic HSEL,
  output logic [ADDR_W-1:0] HADDR,
  output logic [31:0] HWDATA,
  output logic [3:0] HWSTRB,
  output logic HWRITE,
  output logic [2:0] HSIZE, HBURST,
  output logic [3:0] HPROT,
  output logic [1:0] HTRANS,
  output logic HMASTLOCK,
  input logic [31:0] HRDATA,
  input logic HREADY, HRESP
);
  initial begin
    HSEL=0; HADDR='0; HWDATA=0; HWSTRB=0; HWRITE=0;
    HSIZE=2; HBURST=0; HPROT=3; HTRANS=0; HMASTLOCK=0;
  end
  task automatic access(input bit wr, input logic [ADDR_W-1:0] addr,
      input logic [31:0] data, output logic [31:0] result,
      output bit error, input logic [2:0] size=3'd2,
      input logic [3:0] strobe=4'hf);
    int error_cycles;
    if (!rst_n) $fatal(1,"CSR transaction requested during reset");
    @(negedge clk);
    HSEL=1; HADDR=addr; HWRITE=wr; HSIZE=size; HTRANS=2;
    HWDATA=32'hbad0add0; HWSTRB=0;
    @(posedge clk);
    while (!HREADY) @(posedge clk);
    @(negedge clk);
    HSEL=0; HTRANS=0; HWDATA=data; HWSTRB=strobe;
    error_cycles=0;
    @(posedge clk);
    while (!HREADY) begin
      if (HRESP) error_cycles++;
      @(posedge clk);
    end
    error=HRESP; result=HRDATA;
    if (HRESP) begin
      error_cycles++;
      if (error_cycles != 2) $fatal(1,"CSR ERROR must be exactly two cycles, got %0d",error_cycles);
    end else if (error_cycles != 0) $fatal(1,"CSR ERROR did not terminate as ERROR");
    @(negedge clk);
    HWDATA=0; HWSTRB=0;
  endtask
  task automatic write_reg(input logic [11:0] offset, input logic [31:0] data,
      input bit expected_error=0);
    logic [31:0] unused_result;
    bit error;
    access(1,ADDR_W'(32'h10080000)+ADDR_W'(offset),data,unused_result,error);
    if (error != expected_error) $fatal(1,"CSR write %h error=%0b expected=%0b",offset,error,expected_error);
  endtask
  task automatic read_reg(input logic [11:0] offset, output logic [31:0] data);
    bit error;
    access(0,ADDR_W'(32'h10080000)+ADDR_W'(offset),0,data,error);
    if (error) $fatal(1,"CSR read unexpectedly failed at %h",offset);
  endtask
endmodule
