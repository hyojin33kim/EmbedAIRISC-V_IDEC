// 실제 Wally SoC의 CPU와 NPU 버스 배선 및 중재와 오류 및 펌웨어 실행을 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_wally_npu_soc;
  timeunit 1ns; timeprecision 1ps;
  import cvw::*;
  `include "config.vh"
  `include "parameter-defs.vh"
  parameter bit BUS_TEST = 1'b1;
  parameter bit NPU_ENABLE = 1'b1;
  function automatic cvw_t test_configuration();
    cvw_t cfg;
    cfg=P;
    cfg.NPU_SUPPORTED=NPU_ENABLE;
    if (BUS_TEST) begin
      cfg.UNCORE_RAM_RANGE=64'hffff;
      cfg.EXT_MEM_SUPPORTED=1'b1;
      cfg.EXT_MEM_BASE=64'h80010000;
      cfg.EXT_MEM_RANGE=64'hffff;
    end
    return cfg;
  endfunction
  localparam cvw_t DUT_P=test_configuration();
  function automatic cvw_t load_configuration(input int bits);
    cvw_t cfg;
    cfg=P; cfg.LLEN=bits;
    return cfg;
  endfunction
  localparam cvw_t LOAD64_P=load_configuration(64), LOAD128_P=load_configuration(128);
  logic clk=0, reset_ext=1, reset, HCLK, HRESETn;
  always #5 clk=~clk;
  logic [33:0] HADDR;
  logic [31:0] HWDATA, HRDATAEXT, GPIOOUT, GPIOEN;
  logic [3:0] HWSTRB, HPROT, SPICS, SDCCS, PWMGPIO;
  logic HWRITE, HREADY, HSELEXT, HREADYEXT, HRESPEXT, HMASTLOCK;
  logic UARTSout, SPIOut, SPICLK, SDCCmd, SDCCLK;
  logic [2:0] HSIZE, HBURST;
  logic [1:0] HTRANS;
  logic [33:0] b_addr;
  logic [31:0] b_wdata;
  logic [3:0] b_strb, b_prot;
  logic b_sel, b_write, b_lock;
  logic [2:0] b_size, b_burst;
  logic [1:0] b_trans;
  logic [5:0] ext_wait=0;
  logic ext_random=0, ext_error=0, ext_error_write=0;
  logic [33:0] ext_error_addr=0;
  logic npu_trans, npu_ready, npu_resp, csr_trans, csr_ready;
  logic [3:0] npu_strobe, csr_strobe;
  logic [31:0] npu_wdata, csr_wdata;
  logic [33:0] npu_addr;
  integer npu_addresses=0, simultaneous_inputs=0, parallel_outputs=0, overlap_responses=0;
  integer checks=0;
  logic [31:0] value;
  bit bus_error;
  string firmware;
  logic [33:0] pma_addr=34'h010080000;
  logic [1:0] pma_size=2;
  logic pma_read=1, pma_write=0, pma_execute=0, pma_atomic=0;
  logic [3:0] pma_cmo=0;
  logic pma_cacheable, pma_idempotent, pma_tim;
  logic [2:0] pma_fault;
  logic [127:0] load_input=0, load128_output;
  logic [63:0] load64_output;
  logic load_fp=0;

  pmachecker #(DUT_P) mmio_attributes (
    .PhysicalAddress(pma_addr), .Size(pma_size), .CMOpM(pma_cmo),
    .AtomicAccessM(pma_atomic), .ExecuteAccessF(pma_execute), .WriteAccessM(pma_write),
    .ReadAccessM(pma_read), .PBMemoryType(2'b0),
    .Cacheable(pma_cacheable), .Idempotent(pma_idempotent), .SelTIM(pma_tim),
    .PMAInstrAccessFaultF(pma_fault[2]), .PMALoadAccessFaultM(pma_fault[1]),
    .PMAStoreAmoAccessFaultM(pma_fault[0])
  );
  subwordread #(LOAD64_P) load64 (
    .ReadDataWordMuxM(load_input[63:0]), .PAdrM(4'b0), .Funct3M(3'b011),
    .FpLoadStoreM(load_fp), .BigEndianM(1'b0), .ReadDataM(load64_output)
  );
  subwordread #(LOAD128_P) load128 (
    .ReadDataWordMuxM(load_input), .PAdrM(4'b0), .Funct3M(3'b011),
    .FpLoadStoreM(load_fp), .BigEndianM(1'b0), .ReadDataM(load128_output)
  );

  wallypipelinedsoc #(.P(DUT_P)) dut (
    .clk, .reset_ext, .reset, .ExternalStall(1'b0),
    .HRDATAEXT, .HREADYEXT, .HRESPEXT, .HSELEXT,
    .HCLK, .HRESETn, .HADDR, .HWDATA, .HWSTRB, .HWRITE, .HSIZE, .HBURST,
    .HPROT, .HTRANS, .HMASTLOCK, .HREADY,
    .TIMECLK(1'b0), .GPIOIN(32'b0), .GPIOOUT, .GPIOEN, .UARTSin(1'b1), .UARTSout,
    .SPIIn(1'b0), .SPIOut, .SPICS, .SPICLK, .SDCIn(1'b0), .SDCCmd, .SDCCS, .SDCCLK, .PWMGPIO
  );
  ahb_master_bfm cpu (
    .clk, .rst_n(HRESETn), .HSEL(b_sel), .HADDR(b_addr), .HWDATA(b_wdata), .HWSTRB(b_strb),
    .HWRITE(b_write), .HSIZE(b_size), .HBURST(b_burst), .HPROT(b_prot), .HTRANS(b_trans), .HMASTLOCK(b_lock),
    .HRDATA(dut.HRDATA), .HREADY(dut.cpu_HREADY), .HRESP(dut.HRESP)
  );
  ahb_sram_model #(.BASE_ADDR(34'h080010000), .BYTES(65536)) external_ram (
    .clk(HCLK), .rst_n(HRESETn), .HADDR, .HWRITE, .HSIZE, .HBURST,
    .HTRANS(HSELEXT ? HTRANS : 2'b00), .HWDATA, .HWSTRB,
    .HRDATA(HRDATAEXT), .HREADY(HREADYEXT), .HRESP(HRESPEXT),
    .wait_cycles(ext_wait), .random_wait(ext_random), .error_enable(ext_error),
    .error_write(ext_error_write), .error_addr(ext_error_addr)
  );
  if (NPU_ENABLE) begin : observe_npu
    assign npu_trans=dut.npugen.npu_HTRANS[1];
    assign npu_ready=dut.npugen.npu_HREADY;
    assign npu_resp=dut.npugen.npu_HRESP;
    assign npu_addr=dut.npugen.npu_HADDR;
    assign npu_strobe=dut.npugen.npu_HWSTRB;
    assign npu_wdata=dut.npugen.npu_HWDATA;
    assign csr_trans=dut.npugen.csr_HSEL && dut.npugen.csr_HTRANS[1];
    assign csr_ready=dut.npugen.csr_HREADY;
    assign csr_strobe=dut.npugen.csr_HWSTRB;
    assign csr_wdata=dut.npugen.csr_HWDATA;
  end else begin : observe_bypass
    assign {npu_trans,npu_ready,npu_resp,npu_addr,npu_strobe,npu_wdata,csr_trans,csr_ready,csr_strobe,csr_wdata}='0;
  end
  always @(posedge clk) if (HRESETn) begin
    if (npu_trans && npu_ready) npu_addresses++;
    if (npu_trans && dut.cpu_HTRANS[1]) simultaneous_inputs++;
    if (csr_trans && HTRANS[1] && dut.uncore_HSEL) parallel_outputs++;
    if (npu_resp && !dut.HRESP) overlap_responses++;
    if (GPIOOUT == 32'hbad00001) $fatal(1,"CPU firmware reported a mismatch");
  end
  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1,"SoC: %s",message);
    checks++;
  endtask
  task automatic reset_soc;
    @(negedge clk); reset_ext=1;
    repeat (8) @(negedge clk);
    reset_ext=0;
    wait(HRESETn === 1'b1);
    repeat (3) @(negedge clk);
  endtask
  task automatic pulse_reset_soc;
    @(negedge clk); #1; reset_ext=1;
    #1; check(reset && !HRESETn,"asynchronous reset assertion between clock edges");
    reset_ext=0;
    #1; check(reset && !HRESETn,"short pulse held until synchronized release");
    @(posedge clk); #1; check(reset && !HRESETn,"first release clock retains reset");
    @(posedge clk); #1; check(!reset && HRESETn,"second release clock exits reset");
    repeat(3) @(negedge clk);
  endtask
  task automatic access(input bit wr, input logic [33:0] addr, input logic [31:0] data,
                        output logic [31:0] result, input logic [2:0] size=2,
                        input logic [3:0] strobe=15, input bit error_expected=0);
    bit error;
    cpu.access(wr,addr,data,result,error,size,strobe);
    check(error == error_expected,$sformatf("AHB response at %h",addr));
  endtask
  task automatic wr32(input logic [33:0] addr, input logic [31:0] data);
    logic [31:0] ignored;
    access(1,addr,data,ignored);
  endtask
  task automatic wr8(input logic [33:0] addr, input logic [7:0] data);
    logic [31:0] ignored;
    access(1,addr,32'(data) << (8*addr[1:0]),ignored,0,4'b1 << addr[1:0]);
  endtask
  task automatic expect32(input logic [33:0] addr, input logic [31:0] expected);
    logic [31:0] result;
    access(0,addr,0,result);
    check(result === expected,$sformatf("read %h got %h expected %h",addr,result,expected));
  endtask
  function automatic byte unsigned memory_byte(input logic [31:0] addr);
    if (addr < 32'h80010000)
      return dut.uncoregen.uncore.ram.ram.memory.ram.RAM[(addr-32'h80000000)>>2][8*addr[1:0]+:8];
    return external_ram.mem[addr-32'h80010000];
  endfunction
  task automatic cfg_fc(input logic [31:0] src=32'h80001001, input logic [31:0] dst=32'h80004001);
    cpu.write_reg('h020,1); cpu.write_reg('h024,src); cpu.write_reg('h028,32'h80002001);
    cpu.write_reg('h02c,dst); cpu.write_reg('h030,32'h80003000);
    cpu.write_reg('h034,32'h00010420); cpu.write_reg('h038,3); cpu.write_reg('h03c,32'h8078);
  endtask
  task automatic completion(input int error_code=0, input logic [31:0] error_addr=0);
    int loops;
    logic [3:0] mask;
    logic [31:0] expected_scratch;
    loops=0;
    while (!dut.NPUIntr) begin
      cpu.read_reg('h000,value);
      check(value == 32'h544e5055,"CPU CSR read while DMA is active");
      wr32(34'h080006000,0);
      mask=4'(loops%15+1); expected_scratch=0;
      for (int lane=0;lane<4;lane++)
        if (mask[lane]) expected_scratch[8*lane+:8]=8'ha5;
      access(1,34'h080006000,32'ha5a5a5a5,value,2,mask);
      expect32(34'h080006000,expected_scratch);
      loops++;
      if (loops>10000) $fatal(1,"NPU timeout");
    end
    cpu.read_reg('h00c,value); check(value == (error_code ? 4:2),"NPU completion status");
    cpu.read_reg('h014,value);
    check(value == 32'(error_code),$sformatf("NPU error code got=%0d expected=%0d address=%h",value,error_code,error_addr));
    cpu.read_reg('h018,value); check(value == error_addr,$sformatf("NPU error address got=%h expected=%h",value,error_addr));
    cpu.write_reg('h00c,6);
    check(!dut.NPUIntr,"NPU IRQ W1C");
  endtask
  initial begin : run
    if (BUS_TEST) begin
      #1;
      check(pma_fault==0 && !pma_cacheable && !pma_idempotent && !pma_tim,"NPU word MMIO attributes");
      pma_write=1; pma_read=0; #1; check(pma_fault==0,"NPU word store permitted");
      pma_read=1; pma_write=0; pma_size=0; #1; check(pma_fault==2,"NPU byte load faults");
      pma_size=1; #1; check(pma_fault==2,"NPU halfword load faults");
      pma_size=2; pma_atomic=1; #1; check(pma_fault==2,"NPU atomic load faults");
      pma_write=1; #1; check(pma_fault==1,"NPU AMO store faults");
      pma_write=0; pma_atomic=0; pma_execute=1; #1;
      check(pma_fault==6,"NPU execute with simultaneous read faults");
      pma_execute=0; pma_cmo=1; #1; check(pma_fault==3,"NPU CBO with simultaneous read faults");
      pma_cmo=0; pma_addr=34'h010080fff; #1; check(pma_fault==0,"NPU final byte in PMA window");
      pma_addr=34'h010081000; #1; check(pma_fault==2,"address beyond NPU window faults");
      pma_addr=34'h110080000; #1; check(pma_fault==2,"high physical bits cannot alias MMIO");
      pma_addr=34'h080000000; #1; check(pma_fault==0 && pma_cacheable && pma_idempotent,"SRAM attributes preserved");
      // The RV32 elaboration repair must preserve signed LD and floating-point NaN boxing.
      load_input=128'h0123456789abcdef_8000000000000001; #1;
      check(load64_output==64'h8000000000000001 && load128_output==128'hffffffffffffffff_8000000000000001,"signed LD");
      load_input=128'h0123456789abcdef_0123456789abcdef; #1;
      check(load64_output==64'h0123456789abcdef && load128_output==128'h0000000000000000_0123456789abcdef,"positive LD");
      load_fp=1; #1;
      check(load64_output==64'h0123456789abcdef && load128_output==128'hffffffffffffffff_0123456789abcdef,"FLD NaN boxing");
      force dut.cpu_HADDR=b_addr; force dut.cpu_HWDATA=b_wdata; force dut.cpu_HWSTRB=b_strb;
      force dut.cpu_HTRANS=b_trans; force dut.cpu_HWRITE=b_write; force dut.cpu_HSIZE=b_size;
      force dut.cpu_HBURST=b_burst; force dut.cpu_HPROT=b_prot; force dut.cpu_HMASTLOCK=b_lock;
      reset_soc();
      cpu.write_reg('h010,3);
      cpu.read_reg('h000,value); check(value == 32'h544e5055,"NPU ID through CPU->matrix->CSR");
      // Depth and 34-bit decode must not alias a lower RAM or CSR address.
      wr32(34'h080000000,32'h11223344); wr32(34'h080008000,32'h55667788); wr32(34'h08000fffc,32'h99aabbcc);
      expect32(34'h080000000,32'h11223344); expect32(34'h080008000,32'h55667788); expect32(34'h08000fffc,32'h99aabbcc);
      expect32(34'h180000000,0); expect32(34'h110080000,0);
      expect32(34'h01007fffc,0);
      access(0,34'h010080ffc,0,value,2,15,1);
      expect32(34'h010081000,0);
      expect32(34'h080000000,32'h11223344);
      for (int lane=0;lane<4;lane++) wr8(34'h080006100+34'(lane),8'(lane+17));
      expect32(34'h080006100,32'h14131211);
      // All arbitrary byte masks are preserved by the write-data USER path.
      for (int mask=1;mask<16;mask++) begin
        logic [31:0] expected_word;
        wr32(34'h080006104,0); expected_word=0;
        for (int lane=0;lane<4;lane++) if (mask & (1<<lane)) expected_word[lane*8+:8]=8'ha5;
        access(1,34'h080006104,32'ha5a5a5a5,value,2,4'(mask));
        expect32(34'h080006104,expected_word);
      end
      access(1,34'h010080000,0,value,2,15,1);
      access(1,34'h010080024,0,value,2,1,1);
      access(0,34'h010080001,0,value,2,15,1);
      access(0,34'h010080000,0,value,0,0,1);
      // IFM and weights are deliberately unaligned, output is exactly 3 bytes.
      for (int i=0;i<128;i++) begin
        wr8(34'h080001001+34'(i),200);
        wr8(34'h080011001+34'(i),200);
        wr8(34'h080002001+34'(i),1);
        wr8(34'h080002081+34'(i),255);
        wr8(34'h080002101+34'(i),2);
      end
      for (int oc=0;oc<3;oc++) begin
        wr32(34'h080003000+34'(12*oc),oc==2 ? 32'hfffffffd:0);
        wr32(34'h080003004+34'(12*oc),1); wr32(34'h080003008+34'(12*oc),32'(oc+7));
      end
      for(int i=-64;i<67;i++) wr8(34'h080004001+34'(i),8'ha5);
      cfg_fc(); cpu.write_reg('h008,1); completion();
      check(memory_byte('h80004001)==208 && memory_byte('h80004002)==88 && memory_byte('h80004003)==228,"FC result via SRAM");
      for(int i=1;i<=64;i++) begin
        check(memory_byte(32'h80004001-32'(i))==8'ha5,"left output guard");
        check(memory_byte(32'h80004003+32'(i))==8'ha5,"right output guard");
      end
      // CPU continues accessing CSR and RAM during an external 32-cycle DMA wait.
      ext_wait=32; cfg_fc(32'h80011001); cpu.write_reg('h008,1); completion();
      check(memory_byte('h80004001)==208,"long-wait DMA result");
      ext_wait=0; ext_error=1; ext_error_write=0; ext_error_addr=34'h080011001;
      cfg_fc(32'h80011001); cpu.write_reg('h008,1); completion(7,32'h80011001);
      ext_wait=3; ext_error_addr=34'h080011010;
      cfg_fc(32'h80011001); cpu.write_reg('h008,1); completion(7,32'h80011010);
      ext_wait=0;
      ext_error_write=1; ext_error_addr=34'h080014001;
      cfg_fc(32'h80001001,32'h80014001); cpu.write_reg('h008,1); completion(8,32'h80014001);
      ext_error_addr=34'h080014002;
      cfg_fc(32'h80001001,32'h80014001); cpu.write_reg('h008,1); completion(8,32'h80014002);
      ext_error=0;
      // The existing NPU specification restricts DMA to system RAM, so its own
      // CSR window is rejected before the otherwise connected SI1 -> MI1 path.
      begin
        int previous_count;
        previous_count=npu_addresses;
        cfg_fc(32'h10080000); cpu.write_reg('h008,1); completion(3,32'h10080000);
        cfg_fc(32'h80001001,32'h10080000); cpu.write_reg('h008,1); completion(3,32'h10080000);
        check(npu_addresses==previous_count,"out-of-range CSR DMA never issues a bus request");
      end
      expect32(34'h010080000,32'h544e5055);
      // PLIC source 15 reaches the actual CPU external interrupt input.
      wr32(34'h00c00003c,1); wr32(34'h00c002000,32'h8000); wr32(34'h00c200000,0);
      cfg_fc(); cpu.write_reg('h008,1);
      wait(dut.NPUIntr); repeat(8) @(negedge clk);
      check(dut.MExtInt,"PLIC source 15 -> CPU MExtInt");
      expect32(34'h00c200004,15); cpu.write_reg('h00c,6); wr32(34'h00c200004,15);
      repeat(8) @(negedge clk); check(!dut.MExtInt,"PLIC claim/clear/complete");
      ext_wait=32; cfg_fc(32'h80011001); cpu.write_reg('h008,1);
      wait(external_ram.d_valid && !HREADYEXT); pulse_reset_soc();
      check(!dut.NPUIntr && !npu_trans && npu_strobe==0,"reset clears pending DMA");
      cpu.write_reg('h010,3); ext_wait=0; cfg_fc(); cpu.write_reg('h008,1); completion();
      check(simultaneous_inputs>0 && parallel_outputs>0,"both input contention and independent output activity observed");
      check(overlap_responses>0,"NPU ERROR isolated from CPU response");
      $display("[PASS] tb_wally_npu_soc bus checks=%0d npu_addresses=%0d contention=%0d parallel=%0d",checks,npu_addresses,simultaneous_inputs,parallel_outputs);
    end else begin
      firmware="cpu.mem";
      if ($value$plusargs("FW=%s",firmware)) begin end
      $readmemh(firmware,dut.uncoregen.uncore.ram.ram.memory.ram.RAM);
      reset_soc();
      wait(GPIOOUT == 32'h600dcafe);
      if (NPU_ENABLE) begin
        check(npu_addresses>0 && simultaneous_inputs>0,"real CPU and DMA both exercised matrix");
      end
      $display("[PASS] tb_wally_npu_soc CPU npu_enable=%b npu_addresses=%0d contention=%0d",NPU_ENABLE,npu_addresses,simultaneous_inputs);
    end
    $finish;
  end
  initial begin #20000000; $fatal(1,"SoC watchdog GPIO=%h",GPIOOUT); end
endmodule
