// 실제 C 계층 정답과 SRAM 경계를 비교하고 tinyNPU 전체 오류 경로를 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_top;
  timeunit 1ns; timeprecision 1ps;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic s_HSEL, s_HWRITE, s_HMASTLOCK, s_HREADY, s_HRESP;
  logic [33:0] s_HADDR;
  logic [31:0] s_HWDATA, s_HRDATA;
  logic [3:0] s_HWSTRB, s_HPROT;
  logic [2:0] s_HSIZE, s_HBURST;
  logic [1:0] s_HTRANS;
  logic [33:0] m_HADDR;
  logic [31:0] m_HWDATA, m_HRDATA;
  logic [3:0] m_HWSTRB, m_HPROT;
  logic [2:0] m_HSIZE, m_HBURST;
  logic [1:0] m_HTRANS;
  logic m_HWRITE, m_HMASTLOCK, m_HREADY, m_HRESP, irq;
  logic [5:0] wait_cycles=0;
  logic random_wait=0, error_enable=0, error_write=0;
  logic [33:0] error_addr=0;
  byte unsigned expected[0:2047];
  string golden;
  integer stream, total, case_start, case_count, processed, scan_count;
  integer case_id, kind, sample, layer_index, op, relu, in_c, in_h, in_w, out_c, iz, oz;
  integer ifm_bytes, weight_bytes, ofm_bytes;
  logic [31:0] src, weight_addr, dst, qp_addr, value, code, reported_addr;
  int before_writes, before_transfers;
  bit scoreboard_enable=0;
  int scoreboard_write_bytes=0;

  tinynpu_top dut(
    .HCLK(clk),.HRESETn(rst_n),
    .s_HSEL,.s_HADDR,.s_HWDATA,.s_HWSTRB,.s_HWRITE,.s_HSIZE,.s_HBURST,
    .s_HPROT,.s_HTRANS,.s_HMASTLOCK,.s_HREADY,.s_HRDATA,.s_HRESP,.s_HREADYOUT(s_HREADY),
    .m_HADDR,.m_HWDATA,.m_HWSTRB,.m_HWRITE,.m_HSIZE,.m_HBURST,
    .m_HPROT,.m_HTRANS,.m_HMASTLOCK,.m_HRDATA,.m_HREADY,.m_HRESP,.irq_o(irq));
  ahb_master_bfm cpu(.clk,.rst_n,.HSEL(s_HSEL),.HADDR(s_HADDR),.HWDATA(s_HWDATA),
    .HWSTRB(s_HWSTRB),.HWRITE(s_HWRITE),.HSIZE(s_HSIZE),.HBURST(s_HBURST),
    .HPROT(s_HPROT),.HTRANS(s_HTRANS),.HMASTLOCK(s_HMASTLOCK),
    .HRDATA(s_HRDATA),.HREADY(s_HREADY),.HRESP(s_HRESP));
  ahb_sram_model ram(.clk,.rst_n,.HADDR(m_HADDR),.HWRITE(m_HWRITE),.HSIZE(m_HSIZE),
    .HBURST(m_HBURST),.HTRANS(m_HTRANS),.HWDATA(m_HWDATA),.HWSTRB(m_HWSTRB),
    .HRDATA(m_HRDATA),.HREADY(m_HREADY),.HRESP(m_HRESP),
    .wait_cycles,.random_wait,.error_enable,.error_write,.error_addr);

  // Check each actual data completion independently of the output byte comparison.
  always @(posedge clk) begin
    if(rst_n && scoreboard_enable && ram.d_valid && m_HREADY && !m_HRESP) begin
      if(m_HPROT !== 4'b0011 || m_HMASTLOCK !== 1'b0)
        $fatal(1,"DMA protection or lock violates top contract");
      if(ram.d_write) begin
        if(ram.d_addr !== 34'(dst)+34'(scoreboard_write_bytes))
          $fatal(1,"output write skipped, duplicated or out of order at %h",ram.d_addr);
        scoreboard_write_bytes += 1 << ram.d_size;
        if(scoreboard_write_bytes>ofm_bytes) $fatal(1,"output write exceeds exact byte range");
      end else if(!((ram.d_addr>=34'(src) && ram.d_addr+(34'd1<<ram.d_size)<=34'(src)+34'(ifm_bytes)) ||
                   (ram.d_addr>=34'(weight_addr) && ram.d_addr+(34'd1<<ram.d_size)<=34'(weight_addr)+34'(weight_bytes)) ||
                   (ram.d_addr>=34'(qp_addr) && ram.d_addr+(34'd1<<ram.d_size)<=34'(qp_addr)+34'(12*out_c))))
        $fatal(1,"DMA read outside exact input, weight or qparam range at %h",ram.d_addr);
    end
  end

  task automatic reset_dut;
    @(negedge clk); rst_n=0;
    repeat(3) @(posedge clk);
    @(negedge clk); rst_n=1;
    repeat(2) @(posedge clk);
    if (m_HTRANS !== 0 || m_HWSTRB !== 0 || irq !== 0)
      $fatal(1,"reset retained DMA or IRQ state");
    cpu.write_reg(12'h010,3);
  endtask

  task automatic load_binary(input string path, input logic [31:0] addr, input int length);
    int fd, count;
    fd=$fopen(path,"rb");
    if (!fd) $fatal(1,"cannot open %s",path);
    count=$fread(ram.mem,fd,int'(addr-32'h80000000),length);
    $fclose(fd);
    if (count != length) $fatal(1,"short binary %s count=%0d expected=%0d",path,count,length);
  endtask

  task automatic configure;
    cpu.write_reg(12'h020,32'(op | (relu<<8)));
    cpu.write_reg(12'h024,src); cpu.write_reg(12'h028,weight_addr);
    cpu.write_reg(12'h02c,dst); cpu.write_reg(12'h030,qp_addr);
    cpu.write_reg(12'h034,32'((in_c<<16)|(in_w<<8)|in_h));
    cpu.write_reg(12'h038,32'(out_c));
    cpu.write_reg(12'h03c,32'((oz<<8)|iz));
  endtask

  task automatic wait_completion(input bit expect_error=0, input int expected_code=0,
                                  input logic [31:0] expected_addr=0);
    fork : completion_timeout
      begin #200000000; $fatal(1,"case %0d timed out",case_id); end
      begin wait(irq === 1'b1); end
    join_any
    disable completion_timeout;
    cpu.read_reg(12'h00c,value);
    if (value !== (expect_error ? 32'd4 : 32'd2))
      $fatal(1,"case %0d status=%h expected error=%b",case_id,value,expect_error);
    cpu.read_reg(12'h014,code); cpu.read_reg(12'h018,reported_addr);
    if (code !== 32'(expected_code) || reported_addr !== expected_addr)
      $fatal(1,"case %0d error code/address=%h/%h expected=%h/%h",
             case_id,code,reported_addr,expected_code,expected_addr);
    cpu.read_reg(12'h01c,value);
    if (value == 0) $fatal(1,"CYCLES did not count command");
    repeat(4) @(posedge clk);
    if (!irq) $fatal(1,"IRQ is not level-sensitive");
    cpu.write_reg(12'h00c,6);
    if (irq) $fatal(1,"W1C did not clear IRQ");
  endtask

  task automatic run_case;
    int fd, count, dst_index;
    string directory;
    directory=$sformatf("%s/case_%05d",golden,case_id);
    // A chained CNN layer consumes the preceding layer's actual SRAM output.
    if (kind != 0 || layer_index == 0 || processed == 0)
      load_binary({directory,"/ifm.bin"},src,ifm_bytes);
    load_binary({directory,"/weight.bin"},weight_addr,weight_bytes);
    load_binary({directory,"/qparam.bin"},qp_addr,12*out_c);
    fd=$fopen({directory,"/expected.bin"},"rb");
    if (!fd) $fatal(1,"cannot open expected output");
    count=$fread(expected,fd,0,ofm_bytes); $fclose(fd);
    if (count != ofm_bytes) $fatal(1,"short expected output");
    dst_index=int'(dst-32'h80000000);
    for(int i=-64;i<ofm_bytes+64;i++) ram.mem[dst_index+i]=8'ha5;
    random_wait=(kind != 0 || sample == 0);
    wait_cycles=0;
    before_writes=ram.write_bytes;
    scoreboard_write_bytes=0;
    scoreboard_enable=1;
    configure();
    cpu.write_reg(12'h008,1);
    if (processed == 0) begin
      cpu.read_reg(12'h00c,value);
      if (!value[0]) $fatal(1,"START did not immediately expose BUSY");
      cpu.write_reg(12'h024,32'h80000000,1);
      cpu.write_reg(12'h008,1,1);
      cpu.write_reg(12'h008,0);
    end
    wait_completion();
    scoreboard_enable=0;
    if (ram.write_bytes-before_writes != ofm_bytes || scoreboard_write_bytes != ofm_bytes)
      $fatal(1,"case %0d wrote %0d bytes expected %0d",case_id,ram.write_bytes-before_writes,ofm_bytes);
    for(int i=0;i<ofm_bytes;i++)
      if(ram.mem[dst_index+i] !== expected[i])
        $fatal(1,"case %0d sample %0d layer %0d byte %0d got=%h expected=%h",
               case_id,sample,layer_index,i,ram.mem[dst_index+i],expected[i]);
    for(int i=0;i<64;i++)
      if(ram.mem[dst_index-64+i] !== 8'ha5 || ram.mem[dst_index+ofm_bytes+i] !== 8'ha5)
        $fatal(1,"case %0d modified output guard byte %0d",case_id,i);
    $display("[PASS] top case=%0d kind=%0d sample=%0d layer=%0d bytes=%0d",case_id,kind,sample,layer_index,ofm_bytes);
  endtask

  task automatic fault_cases;
    int frozen, expected_code, field_offset, bad_channel;
    logic [31:0] expected_addr, weight_zero_value, multiplier_value, shift_value;
    bit channel_zero_completed;
    op=1; relu=0; in_c=1; in_h=1; in_w=1; out_c=1; iz=0; oz=62;
    src=32'h80001001; weight_addr=32'h80008003; dst=32'h80004003; qp_addr=32'h80007000;
    random_wait=0; wait_cycles=0;
    ram.mem['h1001]=8'd4; ram.mem['h8003]=8'd1; ram.mem['h8004]=8'd1;
    for(int i=0;i<24;i++) ram.mem['h7000+i]=0;
    ram.mem['h7004]=1; ram.mem['h7008]=1; ram.mem['h7010]=1; ram.mem['h7014]=1;
    for(int bad_cfg=0;bad_cfg<8;bad_cfg++) begin
      configure();
      expected_code=0; expected_addr=0;
      case(bad_cfg)
        0: begin cpu.write_reg(12'h020,2); expected_code=1; end
        1: begin cpu.write_reg(12'h034,32'h00010100); expected_code=2; end
        2: begin
          cpu.write_reg(12'h030,qp_addr+1); expected_code=4; expected_addr=qp_addr+1;
        end
        3: begin
          cpu.write_reg(12'h024,32'hffffffff); expected_code=3; expected_addr=32'hffffffff;
        end
        4: begin
          cpu.write_reg(12'h028,32'h7fffffff); expected_code=3; expected_addr=32'h7fffffff;
        end
        5: begin
          cpu.write_reg(12'h02c,32'h88000000); expected_code=3; expected_addr=32'h88000000;
        end
        6: begin
          cpu.write_reg(12'h030,32'hfffffffc); expected_code=3; expected_addr=32'hfffffffc;
        end
        7: begin
          cpu.write_reg(12'h02c,src); expected_code=5; expected_addr=src;
        end
      endcase
      before_transfers=ram.accepted_count;
      cpu.write_reg(12'h008,1); wait_completion(1,expected_code,expected_addr);
      if(ram.accepted_count != before_transfers) $fatal(1,"invalid cfg %0d issued DMA",bad_cfg);
      cpu.read_reg(12'h00c,value); cpu.read_reg(12'h014,code); cpu.read_reg(12'h018,reported_addr);
      if(value !== 0 || code !== 0 || reported_addr !== 0)
        $fatal(1,"configuration error W1C retained status/code/address");
    end
    configure();
    before_writes=ram.write_bytes;
    cpu.write_reg(12'h008,1); wait_completion();
    if(ram.write_bytes != before_writes+1 || ram.mem['h4003] !== 8'd64)
      $fatal(1,"valid START after configuration errors did not recover");
    for(int bad_qp=0;bad_qp<8;bad_qp++) begin
      bad_channel=bad_qp==7 ? 1 : 0;
      out_c=bad_channel+1;
      configure();
      for(int channel=0;channel<2;channel++) begin
        for(int i=0;i<12;i++) ram.mem['h7000+channel*12+i]=0;
        ram.mem['h7000+channel*12+4]=1; ram.mem['h7000+channel*12+8]=1;
      end
      weight_zero_value=0; multiplier_value=1; shift_value=1; field_offset=0;
      case(bad_qp)
        0: begin weight_zero_value=128; multiplier_value=0; shift_value=0; end
        1: weight_zero_value=32'hffffff7f;
        2: begin multiplier_value=0; shift_value=0; field_offset=4; end
        3: begin multiplier_value=32'hffffffff; field_offset=4; end
        4: begin shift_value=0; field_offset=8; end
        5: begin shift_value=63; field_offset=8; end
        6: begin shift_value=32'h10000001; field_offset=8; end
        7: begin shift_value=63; field_offset=8; end
      endcase
      for(int lane=0;lane<4;lane++) begin
        ram.mem['h7000+bad_channel*12+lane]=weight_zero_value[8*lane+:8];
        ram.mem['h7000+bad_channel*12+4+lane]=multiplier_value[8*lane+:8];
        ram.mem['h7000+bad_channel*12+8+lane]=shift_value[8*lane+:8];
      end
      for(int i=-64;i<out_c+64;i++) ram.mem['h4003+i]=8'ha5;
      before_writes=ram.write_bytes;
      channel_zero_completed=0;
      fork : observe_channel_retirement
        begin
          wait(dut.compute_rsp_valid && dut.compute_rsp_ready && !dut.compute_rsp_error && dut.compute_oc==0);
          channel_zero_completed=1;
        end
      join_none
      cpu.write_reg(12'h008,1); wait_completion(1,6,qp_addr+32'(12*bad_channel+field_offset));
      disable observe_channel_retirement;
      if(ram.write_bytes != before_writes) $fatal(1,"invalid qparam %0d wrote external OFM",bad_qp);
      for(int i=-64;i<out_c+64;i++)
        if(ram.mem['h4003+i] !== 8'ha5) $fatal(1,"qparam error modified OFM or guard");
      if(channel_zero_completed !== (bad_channel==1))
        $fatal(1,"qparam error did not preserve the expected completed channel count");
      frozen=ram.accepted_count;
      repeat(20) @(posedge clk);
      if(ram.accepted_count != frozen) $fatal(1,"DMA continued after qparam error");
      cpu.read_reg(12'h00c,value); cpu.read_reg(12'h014,code); cpu.read_reg(12'h018,reported_addr);
      if(value !== 0 || code !== 0 || reported_addr !== 0)
        $fatal(1,"qparam error W1C retained status/code/address");
    end
    out_c=1;
    for(int i=0;i<12;i++) ram.mem['h7000+i]=0;
    ram.mem['h7004]=1; ram.mem['h7008]=1;
    configure();
    before_writes=ram.write_bytes;
    cpu.write_reg(12'h008,1); wait_completion();
    if(ram.write_bytes != before_writes+1 || ram.mem['h4003] !== 8'd64)
      $fatal(1,"valid START after qparam errors did not recover");
    error_enable=1; error_write=0; error_addr={2'b0,src};
    cpu.write_reg(12'h008,1); wait_completion(1,7,src);
    frozen=ram.accepted_count;
    repeat(20) @(posedge clk);
    if(ram.accepted_count != frozen) $fatal(1,"DMA continued after error");
    error_write=1; error_addr={2'b0,dst};
    cpu.write_reg(12'h008,1); wait_completion(1,8,dst);
    error_enable=0;
    wait_cycles=32;
    cpu.write_reg(12'h008,1); wait_completion();
    if(ram.mem['h4003] != 8'd64) $fatal(1,"recovery after errors failed");
    cpu.write_reg(12'h008,1);
    wait(m_HTRANS[1]);
    reset_dut();
    configure();
    cpu.write_reg(12'h008,1); wait_completion();
    if(ram.mem['h4003] != 8'd64) $fatal(1,"recovery after reset failed");
    $display("[PASS] top cfg rejection=8 qparam rejection=8, DMA read/write ERROR, W1C/START recovery, long wait, in-flight reset");
  endtask

  initial begin
    golden="../golden"; case_start=0; case_count=0; processed=0;
    if($value$plusargs("GOLDEN=%s",golden)) begin end
    if($value$plusargs("CASE_START=%d",case_start)) begin end
    if($value$plusargs("CASE_COUNT=%d",case_count)) begin end
    reset_dut();
    cpu.read_reg(12'h000,value);
    if(value !== 32'h544e5055) $fatal(1,"invalid ID");
    cpu.read_reg(12'h004,value);
    if(value !== 32'h00010000) $fatal(1,"invalid VERSION");
    stream=$fopen({golden,"/cases.txt"},"r");
    if(!stream) $fatal(1,"missing golden cases.txt");
    scan_count=$fscanf(stream,"%d\n",total);
    if(scan_count != 1) $fatal(1,"invalid case manifest header");
    for(int row=0;row<total;row++) begin
      scan_count=$fscanf(stream,"%d %d %d %d %d %d %d %d %d %d %d %d %h %h %h %h %d %d %d\n",
        case_id,kind,sample,layer_index,op,relu,in_c,in_h,in_w,out_c,iz,oz,
        src,weight_addr,dst,qp_addr,ifm_bytes,weight_bytes,ofm_bytes);
      if(scan_count != 19) $fatal(1,"invalid manifest row %0d count=%0d",row,scan_count);
      if(row>=case_start && (case_count==0 || processed<case_count)) begin
        run_case(); processed++;
      end
    end
    $fclose(stream);
    if(processed==0) $fatal(1,"no cases selected");
    if(case_start==0) fault_cases();
    $display("[PASS] tb_tinynpu_top cases=%0d",processed);
    $finish;
  end
endmodule
