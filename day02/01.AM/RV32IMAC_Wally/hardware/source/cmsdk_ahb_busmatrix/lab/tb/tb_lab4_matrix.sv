// Lab 4: 생성된 CMSDK 2x2 매트릭스(wally_npu_matrix_lite)에 burst master 2개와 slave 2개를 연결해 주소 decode와 중재를 관찰한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_lab4_matrix;
  localparam int AW = 34;
  logic HCLK = 0, HRESETn = 0;
  always #5 HCLK = ~HCLK;
  int cycle = 0;
  always @(posedge HCLK) cycle++;

  // ---- master 0 (SI0, CPU 역할) · master 1 (SI1, DMA 역할)
  logic          cmd_valid [2] = '{0, 0}, cmd_write [2] = '{0, 0};
  logic          cmd_ready [2], rsp_valid [2], rsp_error [2];
  logic [AW-1:0] cmd_addr [2] = '{0, 0}, rsp_error_addr [2];
  logic [2:0]    cmd_burst [2] = '{0, 0};
  logic [4:0]    rsp_beats [2];
  logic [31:0]   wbuf0 [16], wbuf1 [16], rbuf0 [16], rbuf1 [16];
  logic [AW-1:0] HADDRS [2];
  logic [1:0]    HTRANSS [2];
  logic          HWRITES [2], HMASTLOCKS [2], HREADYS [2], HRESPS [2];
  logic [2:0]    HSIZES [2], HBURSTS [2];
  logic [3:0]    HPROTS [2], HRUSERS [2];
  logic [31:0]   HWDATAS [2], HRDATAS [2];
  // ---- slave 0 (MI0, uncore SRAM 역할) · slave 1 (MI1, NPU CSR 역할)
  logic          HSELM [2], HWRITEM [2], HMASTLOCKM [2], HREADYMUXM [2], HREADYOUTM [2], HRESPM [2];
  logic [AW-1:0] HADDRM [2];
  logic [1:0]    HTRANSM [2];
  logic [2:0]    HSIZEM [2], HBURSTM [2];
  logic [3:0]    HPROTM [2], HAUSERM [2], HWUSERM [2];
  logic [31:0]   HWDATAM [2], HRDATAM [2];
  logic          scan_out;

  ahb_lab_burst_master #(.ADDR_W(AW)) u_m0 (.HCLK, .HRESETn, .cmd_valid(cmd_valid[0]), .cmd_ready(cmd_ready[0]),
    .cmd_write(cmd_write[0]), .cmd_addr(cmd_addr[0]), .cmd_burst(cmd_burst[0]), .wbuf(wbuf0), .rbuf(rbuf0),
    .rsp_valid(rsp_valid[0]), .rsp_error(rsp_error[0]), .rsp_error_addr(rsp_error_addr[0]), .rsp_beats(rsp_beats[0]),
    .HADDR(HADDRS[0]), .HTRANS(HTRANSS[0]), .HWRITE(HWRITES[0]), .HSIZE(HSIZES[0]), .HBURST(HBURSTS[0]),
    .HPROT(HPROTS[0]), .HMASTLOCK(HMASTLOCKS[0]), .HWDATA(HWDATAS[0]), .HRDATA(HRDATAS[0]),
    .HREADY(HREADYS[0]), .HRESP(HRESPS[0]));
  ahb_lab_burst_master #(.ADDR_W(AW)) u_m1 (.HCLK, .HRESETn, .cmd_valid(cmd_valid[1]), .cmd_ready(cmd_ready[1]),
    .cmd_write(cmd_write[1]), .cmd_addr(cmd_addr[1]), .cmd_burst(cmd_burst[1]), .wbuf(wbuf1), .rbuf(rbuf1),
    .rsp_valid(rsp_valid[1]), .rsp_error(rsp_error[1]), .rsp_error_addr(rsp_error_addr[1]), .rsp_beats(rsp_beats[1]),
    .HADDR(HADDRS[1]), .HTRANS(HTRANSS[1]), .HWRITE(HWRITES[1]), .HSIZE(HSIZES[1]), .HBURST(HBURSTS[1]),
    .HPROT(HPROTS[1]), .HMASTLOCK(HMASTLOCKS[1]), .HWDATA(HWDATAS[1]), .HRDATA(HRDATAS[1]),
    .HREADY(HREADYS[1]), .HRESP(HRESPS[1]));

  wally_npu_matrix_lite u_matrix (
    .HCLK, .HRESETn, .REMAP(4'b0),
    .HADDRS0(HADDRS[0]), .HTRANSS0(HTRANSS[0]), .HWRITES0(HWRITES[0]), .HSIZES0(HSIZES[0]), .HBURSTS0(HBURSTS[0]),
    .HPROTS0(HPROTS[0]), .HWDATAS0(HWDATAS[0]), .HMASTLOCKS0(HMASTLOCKS[0]), .HAUSERS0(4'b0), .HWUSERS0(4'b0),
    .HADDRS1(HADDRS[1]), .HTRANSS1(HTRANSS[1]), .HWRITES1(HWRITES[1]), .HSIZES1(HSIZES[1]), .HBURSTS1(HBURSTS[1]),
    .HPROTS1(HPROTS[1]), .HWDATAS1(HWDATAS[1]), .HMASTLOCKS1(HMASTLOCKS[1]), .HAUSERS1(4'b0), .HWUSERS1(4'b0),
    .HRDATAM0(HRDATAM[0]), .HREADYOUTM0(HREADYOUTM[0]), .HRESPM0(HRESPM[0]), .HRUSERM0(4'b0),
    .HRDATAM1(HRDATAM[1]), .HREADYOUTM1(HREADYOUTM[1]), .HRESPM1(HRESPM[1]), .HRUSERM1(4'b0),
    .SCANENABLE(1'b0), .SCANINHCLK(1'b0),
    .HSELM0(HSELM[0]), .HADDRM0(HADDRM[0]), .HTRANSM0(HTRANSM[0]), .HWRITEM0(HWRITEM[0]), .HSIZEM0(HSIZEM[0]),
    .HBURSTM0(HBURSTM[0]), .HPROTM0(HPROTM[0]), .HWDATAM0(HWDATAM[0]), .HMASTLOCKM0(HMASTLOCKM[0]),
    .HREADYMUXM0(HREADYMUXM[0]), .HAUSERM0(HAUSERM[0]), .HWUSERM0(HWUSERM[0]),
    .HSELM1(HSELM[1]), .HADDRM1(HADDRM[1]), .HTRANSM1(HTRANSM[1]), .HWRITEM1(HWRITEM[1]), .HSIZEM1(HSIZEM[1]),
    .HBURSTM1(HBURSTM[1]), .HPROTM1(HPROTM[1]), .HWDATAM1(HWDATAM[1]), .HMASTLOCKM1(HMASTLOCKM[1]),
    .HREADYMUXM1(HREADYMUXM[1]), .HAUSERM1(HAUSERM[1]), .HWUSERM1(HWUSERM[1]),
    .HRDATAS0(HRDATAS[0]), .HREADYS0(HREADYS[0]), .HRESPS0(HRESPS[0]), .HRUSERS0(HRUSERS[0]),
    .HRDATAS1(HRDATAS[1]), .HREADYS1(HREADYS[1]), .HRESPS1(HRESPS[1]), .HRUSERS1(HRUSERS[1]),
    .SCANOUTHCLK(scan_out));

  ahb_lab_slave #(.ADDR_W(AW), .WAIT_STATES(1)) u_s0 (.HCLK, .HRESETn, .HSEL(HSELM[0]), .HADDR(HADDRM[0]),
    .HTRANS(HTRANSM[0]), .HWRITE(HWRITEM[0]), .HSIZE(HSIZEM[0]), .HWDATA(HWDATAM[0]), .HREADY(HREADYMUXM[0]),
    .HRDATA(HRDATAM[0]), .HREADYOUT(HREADYOUTM[0]), .HRESP(HRESPM[0]));
  ahb_lab_slave #(.ADDR_W(AW), .WAIT_STATES(0)) u_s1 (.HCLK, .HRESETn, .HSEL(HSELM[1]), .HADDR(HADDRM[1]),
    .HTRANS(HTRANSM[1]), .HWRITE(HWRITEM[1]), .HSIZE(HSIZEM[1]), .HWDATA(HWDATAM[1]), .HREADY(HREADYMUXM[1]),
    .HRDATA(HRDATAM[1]), .HREADYOUT(HREADYOUTM[1]), .HRESP(HRESPM[1]));
  ahb_checker #(.ADDR_W(AW), .NAME("SI0")) u_check0 (.HCLK, .HRESETn, .HADDR(HADDRS[0]), .HTRANS(HTRANSS[0]),
    .HWRITE(HWRITES[0]), .HSIZE(HSIZES[0]), .HBURST(HBURSTS[0]), .HREADY(HREADYS[0]), .HRESP(HRESPS[0]));
  ahb_checker #(.ADDR_W(AW), .NAME("SI1")) u_check1 (.HCLK, .HRESETn, .HADDR(HADDRS[1]), .HTRANS(HTRANSS[1]),
    .HWRITE(HWRITES[1]), .HSIZE(HSIZES[1]), .HBURST(HBURSTS[1]), .HREADY(HREADYS[1]), .HRESP(HRESPS[1]));

  // slave 쪽에서 수락된 주소 단계를 기록한다 (어느 MI로 갔는지, 어떤 순서였는지)
  logic [AW-1:0] log_addr [2][$];
  int            log_cycle [2][$];
  always @(posedge HCLK) if (HRESETn)
    for (int s = 0; s < 2; s++)
      if (HSELM[s] && HTRANSM[s][1] && HREADYMUXM[s]) begin log_addr[s].push_back(HADDRM[s]); log_cycle[s].push_back(cycle); end

  // >>> TODO(Lab 4): xml/wally_npu_2x2.xml과 wally_mtx_arb.v를 읽고 예측한다.
  //     exp_target: 각 주소가 도착할 출력 포트 (0 = MI0 uncore, 1 = MI1 NPU CSR)
  //     exp_first : S3에서 두 master가 같은 cycle에 SRAM burst를 요청할 때 먼저 grant 받는 master (0 / 1)
  //     힌트: S2가 끝난 뒤 MI0 arbiter의 i_addr_in_port 값, p_sel_port_comb의 (HMASTLOCKM | next_burst_hold) 조건
  localparam int NADDR = 6;
  logic [AW-1:0] probe [NADDR] = '{34'h0_1007_FFFC, 34'h0_1008_0000, 34'h0_1008_0FFC,
                                   34'h0_1008_1000, 34'h0_8000_0000, 34'h3_FFFF_FFFC};
  int exp_target [NADDR] = '{default: -1};
  int exp_first = -1;
  // <<< TODO

  int checks = 0, failures = 0;
  task automatic check(input bit ok, input string message);
    checks++;
    if (!ok) failures++;
    $display("[LAB4] %-56s %s", message, ok ? "OK" : "다시 확인");
  endtask

  task automatic start(input int m, input bit write, input logic [AW-1:0] addr, input logic [2:0] kind);
    cmd_valid[m] = 1; cmd_write[m] = write; cmd_addr[m] = addr; cmd_burst[m] = kind;
  endtask
  task automatic wait_done(input int m, output int finished);
    while (!rsp_valid[m]) @(posedge HCLK);
    finished = cycle;
  endtask

`ifdef FSDB
  initial begin
    string file = "lab4.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, tb_lab4_matrix);
  end
`endif

  initial begin
    int t0, done0, done1, before0, before1, first, switched;
    bit contiguous;
    for (int i = 0; i < 16; i++) begin wbuf0[i] = 32'hA0000000 + i; wbuf1[i] = 32'hB0000000 + i; end
    repeat (2) @(posedge HCLK);
    @(negedge HCLK); HRESETn = 1;

    // S1: 주소 decode — master 1이 SINGLE read를 하나씩 보내고 어느 slave가 받았는지 본다
    for (int i = 0; i < NADDR; i++) begin
      int got;
      before0 = log_addr[0].size(); before1 = log_addr[1].size();
      @(negedge HCLK); start(1, 0, probe[i], 3'b000);
      @(negedge HCLK); cmd_valid[1] = 0;
      wait_done(1, done1);
      got = log_addr[1].size() > before1 ? 1 : (log_addr[0].size() > before0 ? 0 : -1);
      check(got == exp_target[i], $sformatf("S1 decode 0x%09h -> MI%0d (예상 MI%0d)", probe[i], got, exp_target[i]));
    end

    // S2: 서로 다른 slave — CPU는 CSR에 INCR8 write, DMA는 SRAM에서 INCR8 read (동시에)
    @(negedge HCLK); t0 = cycle;
    start(0, 1, 34'h0_1008_0000, 3'b101); start(1, 0, 34'h0_8000_0200, 3'b101);
    @(negedge HCLK); cmd_valid[0] = 0; cmd_valid[1] = 0;
    fork wait_done(0, done0); wait_done(1, done1); join
    $display("[LAB4] S2 parallel: CPU->CSR done +%0d cycles, DMA->SRAM done +%0d cycles", done0 - t0, done1 - t0);
    check(done1 - t0 < 8 + 17, "S2 two outputs run in parallel (DMA does not wait for CPU)");

    // S3: 같은 slave — 두 master가 같은 cycle에 SRAM으로 INCR8 write
    before0 = log_addr[0].size();
    @(negedge HCLK); t0 = cycle;
    start(0, 1, 34'h0_8000_0000, 3'b101); start(1, 1, 34'h0_8000_0200, 3'b101);
    @(negedge HCLK); cmd_valid[0] = 0; cmd_valid[1] = 0;
    fork wait_done(0, done0); wait_done(1, done1); join
    first = log_addr[0][before0][9] ? 1 : 0;
    contiguous = 1;
    for (int i = 0; i < 16; i++)
      if ((log_addr[0][before0 + i][9] ? 1 : 0) != (i < 8 ? first : 1 - first)) contiguous = 0;
    switched = log_cycle[0][before0 + 8] - log_cycle[0][before0 + 7];
    $display("[LAB4] S3 same slave: master %0d first, M0 done +%0d, M1 done +%0d cycles", first, done0 - t0, done1 - t0);
    check(first == exp_first, $sformatf("S3 first grant = master %0d (예상 %0d)", first, exp_first));
    check(contiguous, "S3 8 beats of one burst are never interleaved (burst hold)");
    check(u_s0.mem[0] == 32'hA0000000 && u_s0.mem[8'h87] == 32'hB0000007, "S3 both bursts written to SRAM");

    // S4: DMA INCR16 read 도중 CPU의 SINGLE read는 burst가 끝날 때까지 대기
    @(negedge HCLK); t0 = cycle;
    start(1, 0, 34'h0_8000_0000, 3'b111);
    repeat (3) @(negedge HCLK);
    cmd_valid[1] = 0; start(0, 0, 34'h0_8000_0004, 3'b000);
    @(negedge HCLK); cmd_valid[0] = 0;
    fork wait_done(0, done0); wait_done(1, done1); join
    $display("[LAB4] S4 SINGLE after INCR16: DMA done +%0d, CPU done +%0d cycles", done1 - t0, done0 - t0);
    check(done0 > done1 && rbuf0[0] == 32'hA0000001, "S4 CPU SINGLE completes after the DMA burst");

    check(u_check0.errors == 0 && u_check1.errors == 0, "protocol checkers on SI0/SI1");
    if (failures == 0) $display("[PASS] lab4 matrix %0d/%0d checks", checks, checks);
    else $display("[TODO] lab4 matrix %0d/%0d checks — 예측값(exp_target, exp_first)과 파형을 확인", checks - failures, checks);
    $finish;
  end
  initial begin #400000; $display("[FAIL] lab4 timeout"); $finish; end
endmodule
