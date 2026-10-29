// tinyNPU 명령의 형상과 외부 메모리 범위를 우선순위대로 검사한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_cfg_check import tinynpu_pkg::*; (
  input npu_cfg_t cfg_i,
  output logic ok_o,
  output npu_shape_t shape_o,
  output npu_error_t error_o
);
  logic [31:0] in_count, out_count, per_oc, weight_count, qp_count;
  logic [31:0] out_h, out_w;
  logic [32:0] src_end, wgt_end, dst_end, qp_end;
  logic shape_bad;

  function automatic logic range_bad(input logic [31:0] base,
                                     input logic [32:0] limit);
    return base < 32'h80000000 || limit > 33'h088000000;
  endfunction

  always_comb begin
    in_count = {24'b0, cfg_i.in_c} * {24'b0, cfg_i.in_h} * {24'b0, cfg_i.in_w};
    out_h = cfg_i.op == OP_CONV_POOL ? ({24'b0, cfg_i.in_h} >> 1) : 32'd1;
    out_w = cfg_i.op == OP_CONV_POOL ? ({24'b0, cfg_i.in_w} >> 1) : 32'd1;
    out_count = {24'b0, cfg_i.out_c} * out_h * out_w;
    per_oc = cfg_i.op == OP_CONV_POOL ? 32'd9 * {24'b0, cfg_i.in_c} : in_count;
    weight_count = per_oc * {24'b0, cfg_i.out_c};
    qp_count = 32'd12 * {24'b0, cfg_i.out_c};
    src_end = {1'b0, cfg_i.src_addr} + {1'b0, in_count};
    wgt_end = {1'b0, cfg_i.weight_addr} + {1'b0, weight_count};
    dst_end = {1'b0, cfg_i.dst_addr} + {1'b0, out_count};
    qp_end = {1'b0, cfg_i.qparam_addr} + {1'b0, qp_count};
    shape_bad = cfg_i.in_c == 0 || cfg_i.in_c > 32 ||
                cfg_i.out_c == 0 || cfg_i.out_c > 32 ||
                cfg_i.in_h == 0 || cfg_i.in_h > 32 ||
                cfg_i.in_w == 0 || cfg_i.in_w > 32 ||
                in_count > 2048 || out_count > 2048;
    if (cfg_i.op == OP_CONV_POOL)
      shape_bad = shape_bad || cfg_i.in_h < 2 || cfg_i.in_w < 2 ||
                  cfg_i.in_h[0] || cfg_i.in_w[0];
    else
      shape_bad = shape_bad || in_count > 128;

    error_o = '0;
    shape_o = '0;
    if (cfg_i.op != OP_CONV_POOL && cfg_i.op != OP_FC)
      error_o.code = E_OP;
    else if (shape_bad)
      error_o.code = E_SHAPE;
    else if (cfg_i.qparam_addr[1:0] != 0) begin
      error_o.code = E_ALIGN;
      error_o.addr = cfg_i.qparam_addr;
    end else if (range_bad(cfg_i.src_addr, src_end)) begin
      error_o.code = E_RANGE;
      error_o.addr = cfg_i.src_addr;
    end else if (range_bad(cfg_i.weight_addr, wgt_end)) begin
      error_o.code = E_RANGE;
      error_o.addr = cfg_i.weight_addr;
    end else if (range_bad(cfg_i.dst_addr, dst_end)) begin
      error_o.code = E_RANGE;
      error_o.addr = cfg_i.dst_addr;
    end else if (range_bad(cfg_i.qparam_addr, qp_end)) begin
      error_o.code = E_RANGE;
      error_o.addr = cfg_i.qparam_addr;
    end else if (({1'b0, cfg_i.dst_addr} < src_end && {1'b0, cfg_i.src_addr} < dst_end) ||
                 ({1'b0, cfg_i.dst_addr} < wgt_end && {1'b0, cfg_i.weight_addr} < dst_end) ||
                 ({1'b0, cfg_i.dst_addr} < qp_end && {1'b0, cfg_i.qparam_addr} < dst_end)) begin
      error_o.code = E_OVERLAP;
      error_o.addr = cfg_i.dst_addr;
    end else begin
      shape_o.out_h = out_h[7:0];
      shape_o.out_w = out_w[7:0];
      shape_o.ifm_bytes = in_count[15:0];
      shape_o.ofm_bytes = out_count[15:0];
      shape_o.wgt_per_oc = per_oc[15:0];
      shape_o.wgt_bytes = weight_count[15:0];
      shape_o.qparam_bytes = qp_count[15:0];
    end
    ok_o = error_o.code == E_NONE;
  end
endmodule
