// 채널 연산 전체를 독립 정수 참조와 비교하고 대기 및 오류 복구를 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_compute;
  import tinynpu_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  npu_cfg_t cfg='0;
  npu_shape_t shape='0;
  npu_qparam_t qp='0;
  logic [7:0] oc=0;
  logic start_valid=0,start_ready,rsp_valid,rsp_ready=0,rsp_error;
  logic ifm_en,wgt_en,ifm_valid=0,wgt_valid=0;
  logic [11:0] ifm_addr,wgt_addr,ofm_addr;
  logic [7:0] ifm_data=0,wgt_data=0,ofm_data;
  logic ofm_valid,ofm_ready=0,mem_fault=0;
  byte unsigned imem[0:2047],omem[0:2047],expected[0:2047];
  byte signed wmem[0:511];
  int writes=0,wgt_reads=0,ifm_reads=0,cases=0;
  int output_first=0,output_count=0;
  bit score=0;
  logic [15:0] random_state=16'h1357;
  npu_cfg_t ag_cfg='0;
  npu_shape_t ag_shape='0;
  logic [7:0] ag_oc=0,ag_oy=0,ag_ox=0,ag_ic=0,ag_fc=0;
  logic ag_py=0,ag_px=0,ag_valid,ag_padding;
  logic [1:0] ag_ky=0,ag_kx=0;
  logic [11:0] ag_ifm,ag_ofm;
  logic [8:0] ag_wgt;
  tinynpu_compute dut (
    .clk,.rst_n,.start_valid_i(start_valid),.start_ready_o(start_ready),.cfg_i(cfg),.shape_i(shape),.oc_i(oc),.qparam_i(qp),
    .rsp_valid_o(rsp_valid),.rsp_ready_i(rsp_ready),.rsp_error_o(rsp_error),
    .ifm_rd_en_o(ifm_en),.wgt_rd_en_o(wgt_en),.ifm_rd_addr_o(ifm_addr),.wgt_rd_addr_o(wgt_addr),
    .ifm_rd_valid_i(ifm_valid),.wgt_rd_valid_i(wgt_valid),.ifm_rd_data_i(ifm_data),.wgt_rd_data_i(wgt_data),
    .ofm_wr_valid_o(ofm_valid),.ofm_wr_ready_i(ofm_ready),.ofm_wr_addr_o(ofm_addr),.ofm_wr_data_o(ofm_data),.mem_fault_i(mem_fault)
  );
  tinynpu_addrgen ag (
    .cfg_i(ag_cfg),.shape_i(ag_shape),.oc_i(ag_oc),.oy_i(ag_oy),.ox_i(ag_ox),.ic_i(ag_ic),
    .py_i(ag_py),.px_i(ag_px),.ky_i(ag_ky),.kx_i(ag_kx),.fc_i_i(ag_fc),
    .valid_o(ag_valid),.padding_o(ag_padding),.ifm_addr_o(ag_ifm),.wgt_addr_o(ag_wgt),.ofm_addr_o(ag_ofm)
  );
  always @(negedge clk) begin
    random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
    ofm_ready=rst_n && random_state[1:0] == 2'b11;
  end
  always @(posedge clk) begin
    ifm_valid <= rst_n && ifm_en;
    wgt_valid <= rst_n && wgt_en;
    if(rst_n && ifm_en) begin
      if(ifm_addr>=2048) $fatal(1,"IFM range");
      ifm_data<=imem[ifm_addr];ifm_reads++;
    end
    if(rst_n && wgt_en) begin
      if(wgt_addr>=512) $fatal(1,"WGT range");
      wgt_data<=wmem[wgt_addr];wgt_reads++;
    end
    if(rst_n && ofm_valid && ofm_ready) begin
      if(ofm_addr>=2048) $fatal(1,"OFM range");
      if(score && (ofm_addr != output_first+writes || ofm_data !== expected[ofm_addr]))
        $fatal(1,"compute case=%0d write=%0d addr=%0d data=%0d expected=%0d",cases,writes,ofm_addr,ofm_data,expected[ofm_addr]);
      omem[ofm_addr]=ofm_data;writes++;
    end
  end
  function automatic byte unsigned reference_q(input longint signed x,input int signed m,input int unsigned s,z,input bit r);
    longint signed p,rounded,q;
    longint unsigned mag,divisor,whole,remn;
    p=x*longint'(m);mag=p<0 ? -p : p;divisor=64'd1<<s;
    whole=mag/divisor;remn=mag%divisor;
    if(remn>divisor/2 || (remn==divisor/2 && whole%2==1)) whole++;
    rounded=p<0 ? -longint'(whole) : longint'(whole);
    if(rounded>2147483647) rounded=2147483647;
    if(rounded< -64'sd2147483648) rounded= -64'sd2147483648;
    q=rounded+longint'(z);
    if(q<(r ? longint'(z):64'sd0)) q=r ? longint'(z):64'sd0;
    if(q>255)q=255;
    return q[7:0];
  endfunction
  task automatic tick;
    @(posedge clk);#1;
  endtask
  task automatic retire(input bit error_expected);
    int count;
    count=0;
    while(!rsp_valid && count<300000) begin tick();count++;end
    if(!rsp_valid || rsp_error !== error_expected) $fatal(1,"compute response error got=%b expected=%b",rsp_error,error_expected);
    repeat(3) begin tick();if(!rsp_valid || rsp_error !== error_expected || start_ready) $fatal(1,"compute response hold");end
    @(negedge clk);rsp_ready=1;tick();
    @(negedge clk);rsp_ready=0;
    if(!start_ready || rsp_valid) $fatal(1,"compute response retirement");
  endtask
  task automatic launch;
    @(negedge clk);if(!start_ready)$fatal(1,"compute busy at launch");start_valid=1;tick();
    @(negedge clk);start_valid=0;
  endtask
  task automatic run_case(input bit is_fc,input int h,w,c,ocs,channel,iz,oz,wz,m,s,input bit r,input int seed);
    longint signed sum,maximum;
    int n,oh,ow,iy,ix,read_count;
    n=h*w*c;oh=is_fc?1:h/2;ow=is_fc?1:w/2;
    cfg='0;cfg.op=is_fc?OP_FC:OP_CONV_POOL;cfg.relu=r;
    cfg.in_h=8'(h);cfg.in_w=8'(w);cfg.in_c=8'(c);cfg.out_c=8'(ocs);
    cfg.input_zero=8'(iz);cfg.output_zero=8'(oz);
    shape='0;shape.out_h=8'(oh);shape.out_w=8'(ow);shape.ifm_bytes=16'(n);shape.ofm_bytes=16'(ocs*oh*ow);
    shape.wgt_per_oc=16'(is_fc?n:9*c);shape.wgt_bytes=16'(int'(shape.wgt_per_oc)*ocs);shape.qparam_bytes=16'(12*ocs);
    qp.weight_zero=wz;qp.multiplier=m;qp.right_shift=s;oc=8'(channel);
    for(int i=0;i<2048;i++) begin imem[i]=8'(i*73+(i/7)*29+seed);omem[i]=8'ha5;expected[i]=8'ha5;end
    for(int i=0;i<512;i++) wmem[i]=8'(i*31+(i/3)*17+seed*3);
    read_count=0;
    for(int oy=0;oy<oh;oy++)for(int ox=0;ox<ow;ox++)begin
      maximum=-64'sd2147483648;
      for(int py=0;py<(is_fc?1:2);py++)for(int px=0;px<(is_fc?1:2);px++)begin
        sum=0;
        if(is_fc)begin
          for(int i=0;i<n;i++)begin
            sum+=(int'(imem[i])-iz)*(int'(wmem[i])-wz);read_count++;
          end
        end else begin
          for(int ic=0;ic<c;ic++)for(int ky=0;ky<3;ky++)for(int kx=0;kx<3;kx++)begin
            iy=oy*2+py+ky-1;ix=ox*2+px+kx-1;
            if(iy>=0 && iy<h && ix>=0 && ix<w)begin
              sum+=(int'(imem[(ic*h+iy)*w+ix])-iz)*(int'(wmem[(ic*3+ky)*3+kx])-wz);read_count++;
            end
          end
        end
        if(sum>maximum)maximum=sum;
      end
      expected[(channel*oh+oy)*ow+ox]=reference_q(maximum,m,s,oz,r);
    end
    writes=0;ifm_reads=0;wgt_reads=0;output_first=channel*oh*ow;output_count=oh*ow;score=1;
    launch();
    cfg='1;shape='1;qp='0;oc='1;
    retire(0);score=0;
    if(writes!=output_count || ifm_reads!=read_count || wgt_reads!=(is_fc?n:oh*ow*4*9*c))
      $fatal(1,"compute transaction count writes=%0d IFM=%0d/%0d WGT=%0d",writes,ifm_reads,read_count,wgt_reads);
    for(int i=0;i<2048;i++)if(omem[i] !== expected[i])$fatal(1,"compute canary case=%0d offset=%0d",cases,i);
    cases++;
  endtask
  task automatic short_cfg;
    cfg='0;cfg.op=OP_FC;cfg.in_h=1;cfg.in_w=1;cfg.in_c=1;cfg.out_c=1;cfg.output_zero=100;
    shape='0;shape.out_h=1;shape.out_w=1;shape.ifm_bytes=1;shape.ofm_bytes=1;shape.wgt_per_oc=1;
    qp.weight_zero=0;qp.multiplier=1;qp.right_shift=1;oc=0;
    imem[0]=3;wmem[0]=1;writes=0;
  endtask
  initial begin
    repeat(2)tick();@(negedge clk);rst_n=1;
    ag_cfg.op=OP_CONV_POOL;ag_cfg.in_h=4;ag_cfg.in_w=4;ag_cfg.in_c=2;ag_cfg.out_c=3;
    ag_shape.out_h=2;ag_shape.out_w=2;ag_shape.ifm_bytes=32;ag_shape.ofm_bytes=12;ag_shape.wgt_per_oc=18;
    for(int channel=0;channel<3;channel++)for(int oy=0;oy<2;oy++)for(int ox=0;ox<2;ox++)
    for(int py=0;py<2;py++)for(int px=0;px<2;px++)for(int ic=0;ic<2;ic++)for(int ky=0;ky<3;ky++)for(int kx=0;kx<3;kx++)begin
      int iy,ix;bit pad;
      ag_oc=8'(channel);ag_oy=8'(oy);ag_ox=8'(ox);ag_py=1'(py);ag_px=1'(px);ag_ic=8'(ic);ag_ky=2'(ky);ag_kx=2'(kx);
      iy=oy*2+py+ky-1;ix=ox*2+px+kx-1;pad=iy<0 || ix<0 || iy>=4 || ix>=4;#1;
      if(!ag_valid || ag_padding!==pad || ag_wgt!=(ic*3+ky)*3+kx || ag_ofm!=(channel*2+oy)*2+ox || ag_ifm!=(pad?0:(ic*4+iy)*4+ix)) $fatal(1,"addrgen convolution formula");
    end
    ag_oc=3;#1;if(ag_valid || ag_ifm || ag_wgt || ag_ofm)$fatal(1,"addrgen bad OC");
    ag_oc=0;ag_ky=3;#1;if(ag_valid)$fatal(1,"addrgen bad kernel");
    ag_cfg.op=OP_FC;ag_shape.ifm_bytes=128;ag_shape.wgt_per_oc=128;ag_shape.ofm_bytes=3;ag_fc=127;#1;
    if(!ag_valid || ag_ifm!=127 || ag_wgt!=127 || ag_padding)$fatal(1,"FC ignores inactive counters");
    ag_fc=128;#1;if(ag_valid || ag_ifm || ag_wgt || ag_ofm)$fatal(1,"FC upper bound");
    run_case(1,1,1,1,1,0,0,100,0,1,1,0,3);
    run_case(1,2,2,32,32,31,255,62,-128,1073741824,39,0,9);
    run_case(1,1,4,32,3,2,128,100,127,2147483647,31,1,7);
    run_case(0,2,2,1,2,1,255,100,-128,1073741824,39,0,11);
    run_case(0,4,4,32,32,31,128,128,127,2147483647,39,0,2);
    run_case(0,32,32,2,8,7,0,0,0,1073741824,39,1,13);
    for(int i=0;i<12;i++)run_case(0,2*(i%3+1),2*(i%4+1),i%5+1,4,i%4,i*21,255-i*17,i*21-128,1073741824,39,i%2,i*11);
    short_cfg();oc=1;launch();retire(1);if(writes)$fatal(1,"invalid addrgen wrote OFM");
    short_cfg();launch();wait(wgt_valid);@(negedge clk);mem_fault=1;tick();@(negedge clk);mem_fault=0;retire(1);
    if(writes)$fatal(1,"fault after RAM read wrote OFM");
    short_cfg();launch();wait(dut.rq_pending);@(negedge clk);mem_fault=1;tick();@(negedge clk);mem_fault=0;retire(1);
    if(writes)$fatal(1,"requant fault wrote OFM");
    run_case(1,1,1,1,1,0,0,100,0,1,1,0,5);
    short_cfg();launch();wait(dut.rq_pending);@(negedge clk);rst_n=0;tick();
    if(rsp_valid || ofm_valid || ifm_en || wgt_en)$fatal(1,"compute reset outputs");
    @(negedge clk);rst_n=1;repeat(8)begin tick();if(rsp_valid || ofm_valid)$fatal(1,"compute stale output after reset");end
    run_case(1,1,1,1,1,0,0,100,0,1,1,0,7);
    $display("[PASS] tb_tinynpu_compute cases=%0d",cases);$finish;
  end
  initial begin #10000000;$fatal(1,"compute timeout");end
endmodule
