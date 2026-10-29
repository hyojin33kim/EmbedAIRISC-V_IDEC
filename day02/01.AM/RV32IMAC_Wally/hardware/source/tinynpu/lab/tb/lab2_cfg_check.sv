// Lab 2: 잘못된 command가 tinynpu_cfg_check에서 어떤 오류 코드와 주소로 거부되는지 예측한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab2_cfg_check;
  import tinynpu_pkg::*;
  npu_cfg_t cfg;
  logic ok;
  npu_shape_t shape;
  npu_error_t error;
  int matched = 0;

  tinynpu_cfg_check dut (.cfg_i(cfg), .ok_o(ok), .shape_o(shape), .error_o(error));

  localparam int N = 11;
  string description [N] = '{
    "기준: Conv2 (8x16x16 -> 16ch)", "OP = 3", "IN_H = 15", "IN_C = 9",
    "FC 32x2x3 -> 32", "QPARAM_ADDR = 0x8000_7002", "SRC_ADDR = 0x7FFF_FF00",
    "DST_ADDR = 0x87FF_FE00", "DST_ADDR = 0x8000_4400", "QPARAM_ADDR = 0x9000_0001",
    "DST_ADDR = 0x8000_7080"};

  // >>> TODO(Lab 2): 각 case의 ERROR_CODE와 ERROR_ADDR, 기준 case의 shape를 예측한다 (모르면 'hff).
  //     우선순위: E_OP > E_SHAPE > E_ALIGN > E_RANGE(SRC>WGT>DST>QP) > E_OVERLAP
  logic [7:0] exp_code [N] = '{default: 8'hff};
  logic [31:0] exp_addr [N] = '{default: 32'hffffffff};
  // 기준 case: out_h, out_w, ifm_bytes, ofm_bytes, wgt_per_oc, wgt_bytes, qparam_bytes
  int exp_shape [7] = '{-1, -1, -1, -1, -1, -1, -1};
  // <<< TODO

  function automatic npu_cfg_t conv2_cfg();
    npu_cfg_t c = '0;
    c.op = OP_CONV_POOL; c.relu = 1;
    c.in_c = 8; c.in_h = 16; c.in_w = 16; c.out_c = 16;
    c.src_addr = 32'h80004000; c.weight_addr = 32'h80008001;
    c.dst_addr = 32'h80005000; c.qparam_addr = 32'h80007000;
    return c;
  endfunction

  function automatic npu_cfg_t case_cfg(input int i);
    npu_cfg_t c = conv2_cfg();
    case (i)
      1: c.op = 2'd3;
      2: c.in_h = 15;
      3: c.in_c = 9;
      4: begin c.op = OP_FC; c.in_c = 32; c.in_h = 2; c.in_w = 3; c.out_c = 32; end
      5: c.qparam_addr = 32'h80007002;
      6: c.src_addr = 32'h7fffff00;
      7: c.dst_addr = 32'h87fffe00;
      8: c.dst_addr = 32'h80004400;
      9: c.qparam_addr = 32'h90000001;
      10: c.dst_addr = 32'h80007080;
      default: begin end
    endcase
    return c;
  endfunction

  initial begin
    int shape_ok;
    for (int i = 0; i < N; i++) begin
      bit same;
      cfg = case_cfg(i);
      #1;
      same = error.code == exp_code[i] && error.addr == exp_addr[i];
      if (same) matched++;
      $display("[LAB2] case %2d %-28s | RTL code=0x%02h addr=0x%08h | 예상 code=0x%02h addr=0x%08h | %s",
               i, description[i], error.code, error.addr, exp_code[i], exp_addr[i], same ? "OK" : "다시 확인");
    end
    cfg = case_cfg(0);
    #1;
    shape_ok = shape.out_h == exp_shape[0] && shape.out_w == exp_shape[1] &&
               shape.ifm_bytes == exp_shape[2] && shape.ofm_bytes == exp_shape[3] &&
               shape.wgt_per_oc == exp_shape[4] && shape.wgt_bytes == exp_shape[5] &&
               shape.qparam_bytes == exp_shape[6];
    $display("[LAB2] 기준 shape RTL: out %0dx%0d ifm=%0d ofm=%0d wgt/oc=%0d wgt=%0d qparam=%0d | %s",
             shape.out_h, shape.out_w, shape.ifm_bytes, shape.ofm_bytes, shape.wgt_per_oc,
             shape.wgt_bytes, shape.qparam_bytes, shape_ok ? "OK" : "다시 확인");
    if (matched == N && shape_ok) $display("[PASS] lab2 cfg_check %0d/%0d 일치, shape 일치", matched, N);
    else $display("[TODO] lab2 cfg_check %0d/%0d 일치, shape %s", matched, N, shape_ok ? "일치" : "불일치");
    $finish;
  end
endmodule
