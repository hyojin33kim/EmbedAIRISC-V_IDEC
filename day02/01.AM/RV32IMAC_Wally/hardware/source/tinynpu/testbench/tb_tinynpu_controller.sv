// 제어기의 단계별 요청 유지와 오류 우선순위 및 응답 소비 후 종료를 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_controller;
  import tinynpu_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic start_valid = 0, start_ready, busy, done_event, error_event, check_ok;
  npu_cfg_t start_cfg, check_cfg, compute_cfg, reference_cfg;
  npu_shape_t check_shape, compute_shape;
  npu_error_t check_error, result_error;
  npu_mem_phase_t phase;
  logic dma_valid, dma_ready, dma_rsp_valid = 0, dma_rsp_ready;
  npu_dma_cmd_t dma_cmd;
  npu_dma_rsp_t dma_rsp;
  logic qp_en, qp_valid = 0;
  logic [4:0] qp_oc;
  npu_qparam_t qp_data, compute_qp;
  logic compute_valid, compute_ready, compute_rsp_valid = 0, compute_rsp_ready;
  logic compute_rsp_error = 0;
  logic [7:0] compute_oc;
  integer tick = 0, dma_count = 0, compute_count = 0;
  integer dma_delay = -1, compute_delay = -1;
  integer fail_dma = -1, fail_qp = -1, fail_compute = -1;
  bit internal_dma = 0;
  integer tests = 0;

  assign dma_ready = rst_n && tick % 4 == 0 && !dma_rsp_valid && dma_delay < 0;
  assign compute_ready = rst_n && tick % 3 == 0 && !compute_rsp_valid && compute_delay < 0;
  tinynpu_cfg_check cfg_check (.cfg_i(check_cfg), .ok_o(check_ok), .shape_o(check_shape), .error_o(check_error));
  tinynpu_controller dut (
    .clk, .rst_n, .start_valid_i(start_valid), .start_ready_o(start_ready), .start_cfg_i(start_cfg),
    .check_cfg_o(check_cfg), .check_ok_i(check_ok), .check_shape_i(check_shape), .check_error_i(check_error),
    .busy_o(busy), .done_event_o(done_event), .error_event_o(error_event), .error_o(result_error),
    .mem_phase_o(phase), .dma_cmd_valid_o(dma_valid), .dma_cmd_ready_i(dma_ready), .dma_cmd_o(dma_cmd),
    .dma_rsp_valid_i(dma_rsp_valid), .dma_rsp_ready_o(dma_rsp_ready), .dma_rsp_i(dma_rsp),
    .qp_rd_en_o(qp_en), .qp_rd_oc_o(qp_oc), .qp_rd_valid_i(qp_valid), .qp_rd_data_i(qp_data),
    .compute_start_valid_o(compute_valid), .compute_start_ready_i(compute_ready),
    .compute_cfg_o(compute_cfg), .compute_shape_o(compute_shape), .compute_oc_o(compute_oc),
    .compute_qparam_o(compute_qp), .compute_rsp_valid_i(compute_rsp_valid),
    .compute_rsp_ready_o(compute_rsp_ready), .compute_rsp_error_i(compute_rsp_error)
  );

  always @(posedge clk) begin
    if (!rst_n) begin
      tick <= 0; dma_count <= 0; compute_count <= 0;
      dma_delay <= -1; compute_delay <= -1;
      dma_rsp_valid <= 0; compute_rsp_valid <= 0; qp_valid <= 0;
      dma_rsp <= '0; qp_data <= '0; compute_rsp_error <= 0;
    end else begin
      tick <= tick + 1;
      qp_valid <= qp_en;
      if (qp_en) begin
        if (phase != MEM_COMPUTE || qp_oc != compute_count)
          $fatal(1, "controller QPARAM read order/phase");
        qp_data.weight_zero <= fail_qp == 0 ? 32'sd128 : -32'sd128;
        qp_data.multiplier <= fail_qp == 1 ? -32'sd1 : 32'sd1;
        qp_data.right_shift <= fail_qp == 2 ? 32'h10000001 : 32'd1;
      end
      if (dma_valid && dma_ready) begin
        if (dma_count == 0) begin
          if (dma_cmd.space != SPACE_QPARAM || dma_cmd.write ||
              dma_cmd.sys_addr != {2'b0,reference_cfg.qparam_addr} || dma_cmd.byte_len != 24)
            $fatal(1, "controller parameter load");
        end else if (dma_count == 1) begin
          if (dma_cmd.space != SPACE_IFM || dma_cmd.write ||
              dma_cmd.sys_addr != {2'b0,reference_cfg.src_addr} || dma_cmd.byte_len != 1)
            $fatal(1, "controller input load");
        end else if (dma_count < 4) begin
          if (dma_cmd.space != SPACE_WGT || dma_cmd.write || dma_cmd.byte_len != 1 ||
              dma_cmd.sys_addr != {2'b0,reference_cfg.weight_addr} + 34'(dma_count-2))
            $fatal(1, "controller per-channel weight load");
        end else if (dma_count == 4) begin
          if (dma_cmd.space != SPACE_OFM || !dma_cmd.write || dma_cmd.byte_len != 2 ||
              dma_cmd.sys_addr != {2'b0,reference_cfg.dst_addr})
            $fatal(1, "controller output store");
        end else $fatal(1, "extra DMA request");
        if (phase != (dma_cmd.write ? MEM_STORE : MEM_LOAD)) $fatal(1, "controller DMA phase");
        dma_rsp.error <= dma_count == fail_dma;
        dma_rsp.internal_error <= dma_count == fail_dma && internal_dma;
        dma_rsp.error_addr <= dma_count == fail_dma ? 34'h080001234 : 34'd0;
        dma_rsp.bytes_done <= dma_cmd.byte_len;
        dma_delay <= 7;
        dma_count <= dma_count + 1;
      end
      if (dma_delay > 0) dma_delay <= dma_delay - 1;
      else if (dma_delay == 0) begin dma_rsp_valid <= 1; dma_delay <= -1; end
      if (dma_rsp_valid && dma_rsp_ready) dma_rsp_valid <= 0;
      if (compute_valid && compute_ready) begin
        if (phase != MEM_COMPUTE || compute_oc != compute_count ||
            compute_cfg != reference_cfg || compute_shape.ofm_bytes != 2 || compute_qp.weight_zero != -128)
          $fatal(1, "controller compute payload/order");
        compute_rsp_error <= compute_count == fail_compute;
        compute_count <= compute_count + 1;
        compute_delay <= 9;
      end
      if (compute_delay > 0) compute_delay <= compute_delay - 1;
      else if (compute_delay == 0) begin compute_rsp_valid <= 1; compute_delay <= -1; end
      if (compute_rsp_valid && compute_rsp_ready) compute_rsp_valid <= 0;
      if (done_event || error_event) begin
        if (!busy || dma_rsp_valid || compute_rsp_valid || dma_delay >= 0 || compute_delay >= 0)
          $fatal(1, "controller completed before response drained");
      end
    end
  end
  task automatic run(input logic [7:0] expected_code, input logic [31:0] expected_addr,
                     input integer expected_dma, input integer expected_compute,
                     input bit invalid_cfg = 0);
    @(negedge clk); rst_n = 0; start_valid = 0;
    repeat (2) @(negedge clk);
    reference_cfg = '0;
    reference_cfg.op = invalid_cfg ? 2'd2 : OP_FC;
    reference_cfg.in_c = 1; reference_cfg.in_h = 1; reference_cfg.in_w = 1; reference_cfg.out_c = 2;
    reference_cfg.src_addr = 'h80001000; reference_cfg.weight_addr = 'h80002000;
    reference_cfg.dst_addr = 'h80003000; reference_cfg.qparam_addr = 'h80004000;
    start_cfg = reference_cfg; rst_n = 1;
    @(negedge clk); if (!start_ready) $fatal(1, "controller not idle"); start_valid = 1;
    @(negedge clk); start_valid = 0; start_cfg = '0;
    while (!done_event && !error_event) @(negedge clk);
    if ((expected_code == 0) != done_event || (expected_code != 0) != error_event ||
        result_error.code != expected_code || result_error.addr != expected_addr)
      $fatal(1, "controller result got=%h/%h expected=%h/%h",result_error.code,result_error.addr,expected_code,expected_addr);
    if (dma_count != expected_dma || compute_count != expected_compute)
      $fatal(1, "controller counts DMA=%0d compute=%0d expected=%0d/%0d",dma_count,compute_count,expected_dma,expected_compute);
    @(negedge clk);
    if (busy || !start_ready || done_event || error_event) $fatal(1, "controller event not one cycle");
    repeat (10) @(negedge clk);
    if (dma_count != expected_dma || compute_count != expected_compute) $fatal(1, "continued after completion");
    tests++;
  endtask
  initial begin
    run(E_NONE,0,5,2);
    run(E_OP,0,0,0,1);
    for (int i=0;i<5;i++) begin
      fail_dma=i;
      run(i==4 ? E_DMA_WRITE:E_DMA_READ,'h80001234,i+1,i<3 ? 0 : i-2);
    end
    fail_dma=0; internal_dma=1; run(E_INTERNAL,'h80001234,1,0);
    fail_dma=-1; internal_dma=0;
    for (int i=0;i<3;i++) begin fail_qp=i; run(E_QPARAM,32'h80004000+32'(4*i),2,0); end
    fail_qp=-1; fail_compute=0; run(E_INTERNAL,0,3,1);
    fail_compute=1; run(E_INTERNAL,0,4,2);
    fail_compute=-1; run(E_NONE,0,5,2);
    $display("[PASS] tb_tinynpu_controller cases=%0d",tests);
    $finish;
  end
  initial begin #1000000; $fatal(1,"controller watchdog"); end
endmodule
