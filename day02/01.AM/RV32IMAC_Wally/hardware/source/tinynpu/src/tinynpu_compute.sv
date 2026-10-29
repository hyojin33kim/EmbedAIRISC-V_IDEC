// 출력 채널 하나의 convolution과 pooling 또는 FC 연산을 수행한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_compute (
  input  logic clk, rst_n,
  input  logic start_valid_i,
  output logic start_ready_o,
  input  tinynpu_pkg::npu_cfg_t cfg_i,
  input  tinynpu_pkg::npu_shape_t shape_i,
  input  logic [7:0] oc_i,
  input  tinynpu_pkg::npu_qparam_t qparam_i,
  output logic rsp_valid_o,
  input  logic rsp_ready_i,
  output logic rsp_error_o,
  output logic ifm_rd_en_o, wgt_rd_en_o,
  output logic [11:0] ifm_rd_addr_o, wgt_rd_addr_o,
  input  logic ifm_rd_valid_i, wgt_rd_valid_i,
  input  logic [7:0] ifm_rd_data_i, wgt_rd_data_i,
  output logic ofm_wr_valid_o,
  input  logic ofm_wr_ready_i,
  output logic [11:0] ofm_wr_addr_o,
  output logic [7:0] ofm_wr_data_o,
  input  logic mem_fault_i
);
  import tinynpu_pkg::*;
  typedef enum logic [4:0] {
    C_IDLE, OUT_INIT, SAMPLE_CLEAR, TAP_ADDR, TAP_WAIT, TAP_MAC, TAP_RETIRE,
    SAMPLE_EMIT, SAMPLE_NEXT, REQUANT_REQ, REQUANT_WAIT, OFM_WRITE, OUT_NEXT, C_ABORT, C_RESP
  } state_t;
  state_t state;
  npu_cfg_t cfg;
  npu_shape_t shape;
  npu_qparam_t qparam;
  logic [7:0] oc, oy, ox, ic, fc_index;
  logic py, px;
  logic [1:0] ky, kx;
  logic addr_valid, padding, pending_padding, ifm_seen, wgt_seen;
  logic [11:0] ifm_addr, ofm_addr;
  logic [8:0] wgt_addr;
  logic [7:0] ifm_byte, wgt_byte;
  logic mac_clear, mac_tap, mac_done, pool_clear, pool_sample, pool_valid;
  logic signed [8:0] mac_a, mac_b;
  logic signed [31:0] acc, pool_max, requant_acc;
  logic rq_req_valid, rq_req_ready, rq_rsp_valid, rq_rsp_ready, rq_pending;
  logic [7:0] rq_result;
  assign start_ready_o = rst_n && state == C_IDLE;
  assign rsp_valid_o = rst_n && state == C_RESP;
  assign ifm_rd_en_o = rst_n && state == TAP_ADDR && addr_valid && !padding && !mem_fault_i;
  assign wgt_rd_en_o = rst_n && state == TAP_ADDR && addr_valid && !mem_fault_i;
  assign ifm_rd_addr_o = ifm_addr;
  assign wgt_rd_addr_o = {3'd0, wgt_addr};
  assign ofm_wr_valid_o = rst_n && state == OFM_WRITE && !mem_fault_i;
  assign mac_clear = state == SAMPLE_CLEAR;
  assign mac_tap = state == TAP_MAC && !mem_fault_i;
  assign mac_a = $signed({1'b0, ifm_byte}) - $signed({1'b0, cfg.input_zero});
  assign mac_b = $signed({wgt_byte[7], wgt_byte}) - $signed(qparam.weight_zero[8:0]);
  assign pool_clear = state == OUT_INIT && cfg.op == OP_CONV_POOL;
  assign pool_sample = state == SAMPLE_EMIT && cfg.op == OP_CONV_POOL && !mem_fault_i;
  assign rq_req_valid = state == REQUANT_REQ && !mem_fault_i;
  assign rq_rsp_ready = state == REQUANT_WAIT || state == C_ABORT;
  tinynpu_addrgen u_addrgen (
    .cfg_i(cfg), .shape_i(shape), .oc_i(oc), .oy_i(oy), .ox_i(ox), .ic_i(ic), .py_i(py), .px_i(px),
    .ky_i(ky), .kx_i(kx), .fc_i_i(fc_index), .valid_o(addr_valid), .padding_o(padding),
    .ifm_addr_o(ifm_addr), .ofm_addr_o(ofm_addr), .wgt_addr_o(wgt_addr)
  );
  tinynpu_mac u_mac (.clk, .rst_n, .clear_i(mac_clear), .tap_valid_i(mac_tap),
    .a_i(mac_a), .b_i(mac_b), .acc_o(acc), .tap_done_o(mac_done));
  tinynpu_pool u_pool (.clk, .rst_n, .clear_i(pool_clear), .sample_valid_i(pool_sample),
    .sample_i(acc), .max_valid_o(pool_valid), .max_o(pool_max));
  tinynpu_requant u_requant (
    .clk, .rst_n, .req_valid_i(rq_req_valid), .req_ready_o(rq_req_ready), .acc_i(requant_acc),
    .multiplier_i(qparam.multiplier), .right_shift_i(qparam.right_shift[5:0]),
    .output_zero_i(cfg.output_zero), .relu_i(cfg.relu),
    .rsp_valid_o(rq_rsp_valid), .rsp_ready_i(rq_rsp_ready), .result_o(rq_result)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= C_IDLE;
      cfg <= '0;
      shape <= '0;
      qparam <= '0;
      oc <= '0;
      oy <= '0;
      ox <= '0;
      ic <= '0;
      fc_index <= '0;
      py <= 1'b0;
      px <= 1'b0;
      ky <= '0;
      kx <= '0;
      pending_padding <= 1'b0;
      ifm_seen <= 1'b0;
      wgt_seen <= 1'b0;
      ifm_byte <= '0;
      wgt_byte <= '0;
      requant_acc <= '0;
      rq_pending <= 1'b0;
      ofm_wr_addr_o <= '0;
      ofm_wr_data_o <= '0;
      rsp_error_o <= 1'b0;
    end else begin
      if (rq_req_valid && rq_req_ready) rq_pending <= 1'b1;
      if (rq_rsp_valid && rq_rsp_ready) rq_pending <= 1'b0;
      if (mem_fault_i && state != C_IDLE && state != C_RESP && state != C_ABORT) begin
        rsp_error_o <= 1'b1;
        state <= C_ABORT;
      end else begin
        case (state)
          C_IDLE: if (start_valid_i) begin
            cfg <= cfg_i;
            shape <= shape_i;
            qparam <= qparam_i;
            oc <= oc_i;
            oy <= '0;
            ox <= '0;
            py <= 1'b0;
            px <= 1'b0;
            ic <= '0;
            ky <= '0;
            kx <= '0;
            fc_index <= '0;
            rsp_error_o <= 1'b0;
            state <= OUT_INIT;
          end
          OUT_INIT: begin
            py <= 1'b0;
            px <= 1'b0;
            state <= SAMPLE_CLEAR;
          end
          SAMPLE_CLEAR: begin
            ic <= '0;
            ky <= '0;
            kx <= '0;
            fc_index <= '0;
            state <= TAP_ADDR;
          end
          TAP_ADDR: begin
            if (!addr_valid) begin
              rsp_error_o <= 1'b1;
              state <= C_ABORT;
            end else begin
              pending_padding <= padding;
              ifm_seen <= padding;
              wgt_seen <= 1'b0;
              if (padding) ifm_byte <= cfg.input_zero;
              ofm_wr_addr_o <= ofm_addr;
              state <= TAP_WAIT;
            end
          end
          TAP_WAIT: begin
            if (ifm_rd_valid_i && !pending_padding) begin
              ifm_byte <= ifm_rd_data_i;
              ifm_seen <= 1'b1;
            end
            if (wgt_rd_valid_i) begin
              wgt_byte <= wgt_rd_data_i;
              wgt_seen <= 1'b1;
            end
            if ((ifm_seen || ifm_rd_valid_i) && (wgt_seen || wgt_rd_valid_i)) state <= TAP_MAC;
          end
          TAP_MAC: state <= TAP_RETIRE;
          TAP_RETIRE: if (mac_done) begin
            if (cfg.op == OP_FC) begin
              if ({8'd0, fc_index} + 16'd1 == shape.ifm_bytes) state <= SAMPLE_EMIT;
              else begin fc_index <= fc_index + 8'd1; state <= TAP_ADDR; end
            end else if (kx != 2'd2) begin
              kx <= kx + 2'd1;
              state <= TAP_ADDR;
            end else if (ky != 2'd2) begin
              kx <= '0;
              ky <= ky + 2'd1;
              state <= TAP_ADDR;
            end else if (ic + 8'd1 != cfg.in_c) begin
              kx <= '0;
              ky <= '0;
              ic <= ic + 8'd1;
              state <= TAP_ADDR;
            end else state <= SAMPLE_EMIT;
          end
          SAMPLE_EMIT: begin
            if (cfg.op == OP_FC) begin requant_acc <= acc; state <= REQUANT_REQ; end
            else state <= SAMPLE_NEXT;
          end
          SAMPLE_NEXT: begin
            if (py && px) begin
              if (pool_valid) begin requant_acc <= pool_max; state <= REQUANT_REQ; end
            end else begin
              px <= !px;
              if (px) py <= 1'b1;
              state <= SAMPLE_CLEAR;
            end
          end
          REQUANT_REQ: if (rq_req_ready) state <= REQUANT_WAIT;
          REQUANT_WAIT: if (rq_rsp_valid) begin
            ofm_wr_data_o <= rq_result;
            state <= OFM_WRITE;
          end
          OFM_WRITE: if (ofm_wr_ready_i) state <= OUT_NEXT;
          OUT_NEXT: begin
            if (cfg.op == OP_FC) state <= C_RESP;
            else if (ox + 8'd1 < shape.out_w) begin ox <= ox + 8'd1; state <= OUT_INIT; end
            else if (oy + 8'd1 < shape.out_h) begin
              ox <= '0;
              oy <= oy + 8'd1;
              state <= OUT_INIT;
            end else state <= C_RESP;
          end
          C_ABORT: if (!rq_pending || (rq_rsp_valid && rq_rsp_ready)) state <= C_RESP;
          C_RESP: if (rsp_ready_i) state <= C_IDLE;
          default: begin rsp_error_o <= 1'b1; state <= C_ABORT; end
        endcase
      end
    end
  end
`ifndef SYNTHESIS
  logic [15:0] output_write_count;
  logic [31:0] channel_outputs, channel_first, channel_limit;
  assign channel_outputs = cfg.op == OP_FC ? 32'd1 :
                           {24'd0, shape.out_h} * {24'd0, shape.out_w};
  assign channel_first = {24'd0, oc} * channel_outputs;
  assign channel_limit = channel_first + channel_outputs;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) output_write_count <= '0;
    else if (start_valid_i && start_ready_o) output_write_count <= '0;
    else if (ofm_wr_valid_o && ofm_wr_ready_i) output_write_count <= output_write_count + 16'd1;
  end
  a_ofm_channel_range: assert property (@(posedge clk) disable iff (!rst_n)
    ofm_wr_valid_o && ofm_wr_ready_i |-> {20'd0, ofm_wr_addr_o} >= channel_first &&
    {20'd0, ofm_wr_addr_o} < channel_limit && ofm_wr_addr_o < 12'd2048 &&
    {16'd0, output_write_count} < channel_outputs) else $fatal(1, "a_ofm_channel_range");
  a_channel_output_count: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid_o && !rsp_error_o |-> {16'd0, output_write_count} == channel_outputs)
    else $fatal(1, "a_channel_output_count");
  a_response_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(rsp_error_o)) else $fatal(1, "a_response_stable");
  a_ofm_stable: assert property (@(posedge clk) disable iff (!rst_n)
    ofm_wr_valid_o && !ofm_wr_ready_i && !mem_fault_i |=>
    mem_fault_i || (ofm_wr_valid_o && $stable({ofm_wr_addr_o, ofm_wr_data_o}))) else $fatal(1, "a_ofm_stable");
`endif
endmodule
