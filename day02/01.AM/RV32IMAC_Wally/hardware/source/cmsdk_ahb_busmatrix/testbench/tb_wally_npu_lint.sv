// 테스트 구동기 경고를 제외하고 실제 설정의 Wally SoC 전체 RTL을 lint한다.
module tb_wally_npu_lint;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"
  logic clk=1'b0, reset_ext=1'b1;
  logic reset, HCLK, HRESETn, HSELEXT;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.AHBW-1:0] HWDATA;
  logic [P.XLEN/8-1:0] HWSTRB;
  logic HWRITE, HMASTLOCK, HREADY, UARTSout, SPIOut, SPICLK, SDCCmd, SDCCLK;
  logic [2:0] HSIZE, HBURST;
  logic [1:0] HTRANS;
  logic [3:0] HPROT, SPICS, SDCCS, PWMGPIO;
  logic [31:0] GPIOOUT, GPIOEN;
  wallypipelinedsoc #(P) dut (
    .clk, .reset_ext, .reset, .ExternalStall(1'b0),
    .HRDATAEXT(32'b0), .HREADYEXT(1'b1), .HRESPEXT(1'b0), .HSELEXT,
    .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST,
    .HPROT, .HTRANS, .HMASTLOCK, .HREADY,
    .TIMECLK(1'b0), .GPIOIN(32'b0), .GPIOOUT, .GPIOEN, .UARTSin(1'b1), .UARTSout,
    .SPIIn(1'b0), .SPIOut, .SPICS, .SPICLK,
    .SDCIn(1'b0), .SDCCmd, .SDCCS, .SDCCLK, .PWMGPIO
  );
endmodule
