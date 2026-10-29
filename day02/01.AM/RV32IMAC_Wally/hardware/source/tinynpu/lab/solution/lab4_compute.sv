// Lab 4: 4x4 입력 한 채널의 Conv3x3+MaxPool을 손으로 계산하고 tinynpu_compute의 tap·cycle 수와 비교한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab4_compute;
  import tinynpu_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  npu_cfg_t cfg = '0;
  npu_shape_t shape = '0;
  npu_qparam_t qp = '0;
  logic start_valid = 0, start_ready, rsp_valid, rsp_ready = 0, rsp_error;
  logic ifm_en, wgt_en, ifm_valid = 0, wgt_valid = 0;
  logic [11:0] ifm_addr, wgt_addr, ofm_addr;
  logic [7:0] ifm_data = 0, wgt_data = 0, ofm_data;
  logic ofm_valid;
  byte unsigned ifm [16], ofm [4];
  byte signed wgt [9];
  int taps = 0, padding_taps = 0, ifm_reads = 0, wgt_reads = 0, writes = 0, cycles = 0;
  bit running = 0;

  tinynpu_compute dut (
    .clk, .rst_n, .start_valid_i(start_valid), .start_ready_o(start_ready), .cfg_i(cfg),
    .shape_i(shape), .oc_i(8'd0), .qparam_i(qp), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .rsp_error_o(rsp_error), .ifm_rd_en_o(ifm_en), .wgt_rd_en_o(wgt_en),
    .ifm_rd_addr_o(ifm_addr), .wgt_rd_addr_o(wgt_addr), .ifm_rd_valid_i(ifm_valid),
    .wgt_rd_valid_i(wgt_valid), .ifm_rd_data_i(ifm_data), .wgt_rd_data_i(wgt_data),
    .ofm_wr_valid_o(ofm_valid), .ofm_wr_ready_i(1'b1), .ofm_wr_addr_o(ofm_addr),
    .ofm_wr_data_o(ofm_data), .mem_fault_i(1'b0));

  // 1-cycle 동기 RAM 모델과 tap·read·write·cycle 계수기
  always @(posedge clk) begin
    ifm_valid <= ifm_en;
    wgt_valid <= wgt_en;
    if (ifm_en) begin ifm_data <= ifm[ifm_addr]; ifm_reads++; end
    if (wgt_en) begin wgt_data <= wgt[wgt_addr]; wgt_reads++; end
    if (ofm_valid) begin ofm[ofm_addr] = ofm_data; writes++; end
    if (dut.state == dut.TAP_ADDR && dut.addr_valid) begin
      taps++;
      if (dut.padding) padding_taps++;
    end
    if (dut.pool_sample)
      $display("[LAB4] 출력(%0d,%0d) sample(py,px)=(%0d,%0d) conv 합 = %0d",
               dut.oy, dut.ox, dut.py, dut.px, dut.acc);
    if (running) cycles++;
  end

  // >>> TODO(Lab 4): 4개 출력값과 tap·padding tap·IFM read·WGT read 수, 총 cycle을 예측한다 (모르면 -1).
  //     cycle: start 수락 다음 cycle부터 rsp_valid가 1이 되는 cycle까지 (per output = 16T + 20, T = 9·IN_C)
  int exp_ofm [4] = '{54, 63, 90, 99};
  int exp_taps = 144, exp_padding = 44, exp_ifm_reads = 100, exp_wgt_reads = 144;
  int exp_cycles = 657;
  // <<< TODO

  function automatic string verdict(input bit ok);
    return ok ? "OK" : "다시 확인";
  endfunction

  task automatic report(input string name, input int measured, input int expected, inout int matched);
    $display("[LAB4] %-22s RTL=%0d 예상=%0d %s", name, measured, expected, verdict(measured == expected));
    if (measured == expected) matched++;
  endtask

`ifdef FSDB
  initial begin
    string file = "lab4.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, lab4_compute);
  end
`endif

  initial begin
    int matched = 0;
    // 입력 1..16 (CHW, IN_C=1), weight 3x3 = 모두 1, scale = 2^30 / 2^30 = 1, ReLU
    for (int i = 0; i < 16; i++) ifm[i] = 8'(i + 1);
    for (int i = 0; i < 9; i++) wgt[i] = 1;
    cfg.op = OP_CONV_POOL; cfg.relu = 1; cfg.in_c = 1; cfg.in_h = 4; cfg.in_w = 4; cfg.out_c = 1;
    shape.out_h = 2; shape.out_w = 2; shape.ifm_bytes = 16; shape.ofm_bytes = 4;
    shape.wgt_per_oc = 9; shape.wgt_bytes = 9; shape.qparam_bytes = 12;
    qp.weight_zero = 0; qp.multiplier = 32'sd1073741824; qp.right_shift = 30;
    repeat (2) @(posedge clk);
    @(negedge clk); rst_n = 1;
    @(negedge clk); start_valid = 1;
    @(posedge clk); #1 running = 1;
    @(negedge clk); start_valid = 0;
    wait (rsp_valid);
    @(posedge clk); #1 running = 0;
    @(negedge clk); rsp_ready = 1;
    @(negedge clk); rsp_ready = 0;
    for (int i = 0; i < 4; i++) report($sformatf("OFM[%0d]", i), ofm[i], exp_ofm[i], matched);
    report("tap 수", taps, exp_taps, matched);
    report("padding tap 수", padding_taps, exp_padding, matched);
    report("IFM read 수", ifm_reads, exp_ifm_reads, matched);
    report("WGT read 수", wgt_reads, exp_wgt_reads, matched);
    report("cycle 수", cycles, exp_cycles, matched);
    if (matched == 9 && !rsp_error) $display("[PASS] lab4 compute 9/9 일치");
    else $display("[TODO] lab4 compute %0d/9 일치 — padding 위치와 tap 4-cycle 구조를 다시 확인", matched);
    $finish;
  end
  initial begin #1000000; $fatal(1, "lab4 timeout"); end
endmodule
