// 내부 메모리의 응답 지연과 byte 순서 및 소유권 오류를 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_memory;
  import tinynpu_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  npu_mem_phase_t phase=MEM_IDLE;
  logic req_valid=0, req_ready, req_write=0, rsp_valid, rsp_ready=0, rsp_error;
  logic [1:0] space=0;
  logic [11:0] addr=0;
  logic [7:0] wdata=0, rdata;
  logic ifm_en=0, wgt_en=0, ifm_valid, wgt_valid;
  logic [11:0] ifm_addr=0, wgt_addr=0;
  logic [7:0] ifm_data,wgt_data;
  logic ofm_valid=0, ofm_ready;
  logic [11:0] ofm_addr=0;
  logic [7:0] ofm_data=0;
  logic qp_en=0, qp_valid, fault;
  logic [4:0] qp_oc=0;
  npu_qparam_t qp_data;
  int checks=0;
  tinynpu_local_mem dut (
    .clk,.rst_n,.phase_i(phase),.dma_req_valid_i(req_valid),.dma_req_ready_o(req_ready),
    .dma_req_write_i(req_write),.dma_req_space_i(space),.dma_req_addr_i(addr),.dma_req_wdata_i(wdata),
    .dma_rsp_valid_o(rsp_valid),.dma_rsp_ready_i(rsp_ready),.dma_rsp_rdata_o(rdata),.dma_rsp_error_o(rsp_error),
    .ifm_rd_en_i(ifm_en),.wgt_rd_en_i(wgt_en),.ifm_rd_addr_i(ifm_addr),.wgt_rd_addr_i(wgt_addr),
    .ifm_rd_valid_o(ifm_valid),.wgt_rd_valid_o(wgt_valid),.ifm_rd_data_o(ifm_data),.wgt_rd_data_o(wgt_data),
    .ofm_wr_valid_i(ofm_valid),.ofm_wr_ready_o(ofm_ready),.ofm_wr_addr_i(ofm_addr),.ofm_wr_data_i(ofm_data),
    .qp_rd_en_i(qp_en),.qp_rd_oc_i(qp_oc),.qp_rd_valid_o(qp_valid),.qp_rd_data_o(qp_data),.compute_fault_o(fault)
  );
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic dma(input bit wr, input logic [1:0] sp, input int a, input byte unsigned d,
                     input bit err, input byte unsigned expected=0);
    @(negedge clk);
    if(!req_ready) $fatal(1,"memory request not ready");
    req_valid=1;req_write=wr;space=sp;addr=12'(a);wdata=d;
    tick();
    if(!rsp_valid || rsp_error !== err || rdata !== (wr || err ? 8'd0 : expected))
      $fatal(1,"DMA memory response sp=%0d addr=%0d wr=%b data=%h err=%b",sp,a,wr,rdata,rsp_error);
    @(negedge clk); req_valid=0; addr='1; wdata=0;
    repeat(2) begin
      tick();
      if(!rsp_valid || req_ready || rsp_error !== err || rdata !== (wr || err ? 8'd0 : expected)) $fatal(1,"memory response hold");
    end
    @(negedge clk);rsp_ready=1;tick();
    if(rsp_valid || !req_ready) $fatal(1,"memory response retirement");
    @(negedge clk);rsp_ready=0;
    checks++;
  endtask
  task automatic read_both(input int ia,wa,input byte unsigned id,wd,input bit err=0);
    @(negedge clk);ifm_en=1;wgt_en=1;ifm_addr=12'(ia);wgt_addr=12'(wa);
    tick();
    if(fault !== err) $fatal(1,"compute read fault addr=%0d/%0d",ia,wa);
    if(!err && (!ifm_valid || !wgt_valid || ifm_data !== id || wgt_data !== wd)) $fatal(1,"compute RAM read data/latency");
    if(err && (ifm_valid || wgt_valid)) $fatal(1,"bad compute read accepted");
    @(negedge clk);ifm_en=0;wgt_en=0;
    tick();if(ifm_valid || wgt_valid || fault) $fatal(1,"read valid/fault must pulse");
    checks++;
  endtask
  task automatic write_ofm(input int a,input byte unsigned d,input bit err=0);
    @(negedge clk);ofm_valid=1;ofm_addr=12'(a);ofm_data=d;
    if(!ofm_ready) $fatal(1,"OFM request not consumable");
    tick();if(fault !== err) $fatal(1,"OFM write fault");
    @(negedge clk);ofm_valid=0;tick();if(fault) $fatal(1,"OFM fault not pulse");
    checks++;
  endtask
  initial begin
    repeat(2) tick();@(negedge clk);rst_n=1;
    dma(1,SPACE_IFM,0,8'h55,1);
    phase=MEM_LOAD;
    dma(1,SPACE_IFM,0,8'h80,0);dma(1,SPACE_IFM,2047,8'hff,0);
    dma(1,SPACE_WGT,0,8'h81,0);dma(1,SPACE_WGT,511,8'hfe,0);
    dma(1,SPACE_IFM,2048,8'h11,1);dma(1,SPACE_WGT,512,8'h22,1);
    dma(1,SPACE_QPARAM,384,8'h33,1);dma(1,SPACE_OFM,0,8'h44,1);
    dma(0,SPACE_IFM,0,0,1);dma(0,SPACE_OFM,0,0,1);
    for(int i=0;i<384;i++) dma(1,SPACE_QPARAM,i,8'(i*7+3),0);
    read_both(0,0,0,0,1);
    phase=MEM_COMPUTE;
    read_both(0,0,8'h80,8'h81);read_both(2047,511,8'hff,8'hfe);
    read_both(2048,512,0,0,1);
    dma(1,SPACE_IFM,0,8'h11,1);dma(0,SPACE_OFM,0,0,1);
    for(int oc=0;oc<32;oc++) begin
      npu_qparam_t expected;
      for(int j=0;j<4;j++) begin
        expected.weight_zero[8*j+:8]=8'((oc*12+j)*7+3);
        expected.multiplier[8*j+:8]=8'((oc*12+4+j)*7+3);
        expected.right_shift[8*j+:8]=8'((oc*12+8+j)*7+3);
      end
      @(negedge clk);qp_en=1;qp_oc=5'(oc);tick();
      if(!qp_valid || qp_data !== expected || fault) $fatal(1,"QPARAM endian/channel %0d got=%h expected=%h",oc,qp_data,expected);
      @(negedge clk);qp_en=0;tick();if(qp_valid) $fatal(1,"QPARAM pulse");
      checks++;
    end
    write_ofm(0,8'h65);write_ofm(2047,8'hab);write_ofm(2048,8'h99,1);
    phase=MEM_STORE;
    dma(0,SPACE_OFM,0,0,0,8'h65);dma(0,SPACE_OFM,2047,0,0,8'hab);
    dma(0,SPACE_OFM,2048,0,1);dma(1,SPACE_OFM,0,0,1);dma(0,SPACE_IFM,0,0,1);
    write_ofm(0,8'h99,1);dma(0,SPACE_OFM,0,0,0,8'h65);
    @(negedge clk);qp_en=1;tick();if(!fault || qp_valid) $fatal(1,"QPARAM phase rejection");
    @(negedge clk);qp_en=0;rst_n=0;tick();
    if(rsp_valid || ifm_valid || wgt_valid || qp_valid || fault) $fatal(1,"memory reset valids");
    @(negedge clk);rst_n=1;phase=MEM_LOAD;
    dma(1,SPACE_IFM,0,8'hc3,0);dma(1,SPACE_WGT,0,8'h3c,0);
    phase=MEM_COMPUTE;read_both(0,0,8'hc3,8'h3c);
    $display("[PASS] tb_tinynpu_memory checks=%0d",checks);$finish;
  end
  initial begin #1000000;$fatal(1,"memory timeout");end
endmodule
