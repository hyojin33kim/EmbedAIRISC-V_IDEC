// NPU firmware harness: actual CPU/SoC RTL and the shared layer/result checker.
// Generic ISA signature/shadow-memory machinery stays in the original VCS TB.
`timescale 1ns/1ps
`include "config.vh"
`include "BranchPredictorType.vh"
import cvw::*;

`ifdef STORY_TRACE
module testbench(output logic story_capture=1'b1);
`else
module testbench;
`endif
  `include "parameter-defs.vh"
  logic clk=1'b0, reset_ext=1'b1, reset;
  logic LoadMem=1'b0, Validate=1'b0;
  logic [31:0] NextInstrE, InstrM;
  string ElfFile, uart_log_file;
  integer uart_file;
  longint unsigned host_cycles=0;

  always #1 clk=~clk;

  wallypipelinedsoc #(P) dut (
    .clk, .reset_ext, .reset, .ExternalStall(1'b0),
    .HRDATAEXT('0), .HREADYEXT(1'b1), .HRESPEXT(1'b0),
    .HSELEXT(), .HCLK(), .HRESETn(), .HADDR(), .HWDATA(), .HWSTRB(),
    .HWRITE(), .HSIZE(), .HBURST(), .HPROT(), .HTRANS(),
    .HMASTLOCK(), .HREADY(), .TIMECLK(1'b0), .GPIOIN('0),
    .GPIOOUT(), .GPIOEN(), .UARTSin(1'b1), .UARTSout(),
    .SPIIn(1'b0), .SPIOut(), .SPICS(), .SPICLK(),
    .SDCIn(1'b1), .SDCCmd(), .SDCCS(), .SDCCLK(), .PWMGPIO()
  );

  // Match the original TB's M-stage instruction register and terminal loop.
  mux2 #(32) FlushInstrMMux(dut.core.ifu.InstrE, dut.core.ifu.nop,
                           dut.core.ifu.FlushM, NextInstrE);
  flopenr #(32) InstrMReg(clk, reset, ~dut.core.ifu.StallM, NextInstrE, InstrM);
  riscvassertions #(P) riscvassertions();
  riscvassertions_wally #(P) riscvassertions_wally();

  initial begin
    if (!$value$plusargs("ElfFile=%s",ElfFile)) $fatal(1,"Missing +ElfFile");
    if (!$value$plusargs("UART_LOG_FILE=%s",uart_log_file)) $fatal(1,"Missing UART log path");
    uart_file=$fopen(uart_log_file,"w");
    if (!uart_file) $fatal(1,"Cannot open UART log");
    repeat (10) @(negedge clk);
    $readmemh({ElfFile,".memfile"},dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
    LoadMem=1'b1;
    @(negedge clk);
    LoadMem=1'b0;
    repeat (8) @(negedge clk);
    reset_ext=1'b0;
    $display("[BOOT] Wally RV32IMAC + tinyNPU firmware=%s",ElfFile);
    wait (!reset && dut.core.InstrValidM && InstrM==32'h0000006f);
    // Firmware flushes results/stats to RAM before returning into end_loop.
    // Leave a full falling edge for the unchanged npu_monitor validation.
    @(negedge clk); #0.1; Validate=1'b1;
    @(negedge clk); #0.1; Validate=1'b0;
    $fclose(uart_file);
    $display("[SIM_DONE] host_clock_cycles=%0d",host_cycles);
    $finish;
  end

  always @(posedge clk) begin
    host_cycles++;
    if (!reset && host_cycles%1000000==0)
      $display("[PROGRESS] cycles=%0d PC=%h completed_layers=%0d DMA=%0d",
               host_cycles,dut.core.ifu.PCF,npu_completed,npu_dma_addresses);
    if (uart_file && !dut.uncoregen.uncore.uartgen.uart.MEMWb &&
        dut.uncoregen.uncore.uartgen.uart.uartPC.A==3'b000 &&
        !dut.uncoregen.uncore.uartgen.uart.uartPC.DLAB) begin
      $fwrite(uart_file,"%c",dut.uncoregen.uncore.uartgen.uart.uartPC.Din);
      $fflush(uart_file);
    end
  end

  `include "npu_monitor.svh"
`ifdef STORY_TRACE
  `include "story_signals.svh"
`endif
endmodule
