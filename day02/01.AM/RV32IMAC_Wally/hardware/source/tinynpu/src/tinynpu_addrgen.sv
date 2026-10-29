// CHW 및 현재 출력 채널의 weight 주소와 padding 여부를 계산한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_addrgen (
  input  tinynpu_pkg::npu_cfg_t cfg_i,
  input  tinynpu_pkg::npu_shape_t shape_i,
  input  logic [7:0] oc_i, oy_i, ox_i, ic_i,
  input  logic py_i, px_i,
  input  logic [1:0] ky_i, kx_i,
  input  logic [7:0] fc_i_i,
  output logic valid_o, padding_o,
  output logic [11:0] ifm_addr_o, ofm_addr_o,
  output logic [8:0] wgt_addr_o
);
  import tinynpu_pkg::*;
  logic signed [31:0] iy, ix;
  logic [31:0] ifm_index, wgt_index, ofm_index;
  always_comb begin
    valid_o = 1'b0;
    padding_o = 1'b0;
    ifm_addr_o = '0;
    ofm_addr_o = '0;
    wgt_addr_o = '0;
    iy = 32'sd2 * $signed({24'd0, oy_i}) + $signed({31'd0, py_i})
       + $signed({30'd0, ky_i}) - 32'sd1;
    ix = 32'sd2 * $signed({24'd0, ox_i}) + $signed({31'd0, px_i})
       + $signed({30'd0, kx_i}) - 32'sd1;
    ifm_index = '0;
    wgt_index = '0;
    ofm_index = '0;
    if (cfg_i.op == OP_CONV_POOL) begin
      valid_o = oc_i < cfg_i.out_c && oy_i < shape_i.out_h && ox_i < shape_i.out_w
             && ic_i < cfg_i.in_c && ky_i < 2'd3 && kx_i < 2'd3;
      padding_o = iy < 0 || ix < 0 || iy >= $signed({24'd0, cfg_i.in_h})
                || ix >= $signed({24'd0, cfg_i.in_w});
      if (!padding_o)
        ifm_index = ({24'd0, ic_i} * {24'd0, cfg_i.in_h} + $unsigned(iy))
                  * {24'd0, cfg_i.in_w} + $unsigned(ix);
      wgt_index = ({24'd0, ic_i} * 32'd3 + {30'd0, ky_i}) * 32'd3 + {30'd0, kx_i};
      ofm_index = ({24'd0, oc_i} * {24'd0, shape_i.out_h} + {24'd0, oy_i})
                * {24'd0, shape_i.out_w} + {24'd0, ox_i};
      valid_o = valid_o && (padding_o || (ifm_index < 32'd2048 && ifm_index < {16'd0, shape_i.ifm_bytes}))
                && wgt_index < 32'd512 && wgt_index < {16'd0, shape_i.wgt_per_oc}
                && ofm_index < 32'd2048 && ofm_index < {16'd0, shape_i.ofm_bytes};
    end else if (cfg_i.op == OP_FC) begin
      ifm_index = {24'd0, fc_i_i};
      wgt_index = {24'd0, fc_i_i};
      ofm_index = {24'd0, oc_i};
      valid_o = oc_i < cfg_i.out_c && {8'd0, fc_i_i} < shape_i.ifm_bytes
                && {8'd0, fc_i_i} < shape_i.wgt_per_oc && fc_i_i < 8'd128
                && {8'd0, oc_i} < shape_i.ofm_bytes;
    end
    if (valid_o) begin
      ifm_addr_o = ifm_index[11:0];
      wgt_addr_o = wgt_index[8:0];
      ofm_addr_o = ofm_index[11:0];
    end else padding_o = 1'b0;
  end
endmodule
