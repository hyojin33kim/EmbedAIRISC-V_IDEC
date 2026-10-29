// 계층의 파라미터와 입력 및 채널별 가중치를 순서대로 로드하고 계산과 저장을 제어한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_controller import tinynpu_pkg::*; (
  input logic clk, rst_n,
  input logic start_valid_i,
  output logic start_ready_o,
  input npu_cfg_t start_cfg_i,
  output npu_cfg_t check_cfg_o,
  input logic check_ok_i,
  input npu_shape_t check_shape_i,
  input npu_error_t check_error_i,
  output logic busy_o, done_event_o, error_event_o,
  output npu_error_t error_o,
  output npu_mem_phase_t mem_phase_o,
  output logic dma_cmd_valid_o,
  input logic dma_cmd_ready_i,
  output npu_dma_cmd_t dma_cmd_o,
  input logic dma_rsp_valid_i,
  output logic dma_rsp_ready_o,
  input npu_dma_rsp_t dma_rsp_i,
  output logic qp_rd_en_o,
  output logic [4:0] qp_rd_oc_o,
  input logic qp_rd_valid_i,
  input npu_qparam_t qp_rd_data_i,
  output logic compute_start_valid_o,
  input logic compute_start_ready_i,
  output npu_cfg_t compute_cfg_o,
  output npu_shape_t compute_shape_o,
  output logic [7:0] compute_oc_o,
  output npu_qparam_t compute_qparam_o,
  input logic compute_rsp_valid_i,
  output logic compute_rsp_ready_o,
  input logic compute_rsp_error_i
);
  typedef enum logic [4:0] {
    IDLE, VALIDATE, QP_LOAD_REQ, QP_LOAD_WAIT, IFM_LOAD_REQ, IFM_LOAD_WAIT,
    OC_INIT, QP_WAIT, QP_CHECK, WGT_LOAD_REQ, WGT_LOAD_WAIT,
    COMPUTE_REQ, COMPUTE_WAIT, NEXT_OC, OFM_STORE_REQ, OFM_STORE_WAIT,
    SUCCESS, FAIL
  } state_t;
  state_t state;
  npu_cfg_t cfg;
  npu_shape_t shape;
  npu_qparam_t qparam;
  logic [7:0] oc;
  logic [31:0] weight_addr, qparam_addr;
  npu_error_t qp_error;

  assign weight_addr = cfg.weight_addr + {24'b0, oc} * {16'b0, shape.wgt_per_oc};
  assign qparam_addr = cfg.qparam_addr + 32'd12 * {24'b0, oc};
  assign check_cfg_o = cfg;
  assign compute_cfg_o = cfg;
  assign compute_shape_o = shape;
  assign compute_oc_o = oc;
  assign compute_qparam_o = qparam;
  assign qp_rd_oc_o = oc[4:0];
  assign start_ready_o = rst_n && state == IDLE;
  assign busy_o = rst_n && state != IDLE;
  assign done_event_o = rst_n && state == SUCCESS;
  assign error_event_o = rst_n && state == FAIL;
  assign qp_rd_en_o = rst_n && state == OC_INIT;
  assign compute_start_valid_o = rst_n && state == COMPUTE_REQ;
  assign compute_rsp_ready_o = rst_n && state == COMPUTE_WAIT;

  always_comb begin
    qp_error = '0;
    if (qparam.weight_zero < -32'sd128 || qparam.weight_zero > 32'sd127) begin
      qp_error.code = E_QPARAM;
      qp_error.addr = qparam_addr;
    end else if (qparam.multiplier <= 32'sd0) begin
      qp_error.code = E_QPARAM;
      qp_error.addr = qparam_addr + 32'd4;
    end else if (qparam.right_shift < 32'd1 || qparam.right_shift > 32'd62) begin
      qp_error.code = E_QPARAM;
      qp_error.addr = qparam_addr + 32'd8;
    end
  end

  always_comb begin
    mem_phase_o = MEM_IDLE;
    dma_cmd_o = '0;
    dma_cmd_valid_o = 1'b0;
    dma_rsp_ready_o = 1'b0;
    if (rst_n) begin
      case (state)
        QP_LOAD_REQ, QP_LOAD_WAIT: begin
          mem_phase_o = MEM_LOAD;
          dma_cmd_o.sys_addr = {2'b0, cfg.qparam_addr};
          dma_cmd_o.byte_len = shape.qparam_bytes;
          dma_cmd_o.space = SPACE_QPARAM;
          dma_cmd_valid_o = state == QP_LOAD_REQ;
          dma_rsp_ready_o = state == QP_LOAD_WAIT;
        end
        IFM_LOAD_REQ, IFM_LOAD_WAIT: begin
          mem_phase_o = MEM_LOAD;
          dma_cmd_o.sys_addr = {2'b0, cfg.src_addr};
          dma_cmd_o.byte_len = shape.ifm_bytes;
          dma_cmd_o.space = SPACE_IFM;
          dma_cmd_valid_o = state == IFM_LOAD_REQ;
          dma_rsp_ready_o = state == IFM_LOAD_WAIT;
        end
        WGT_LOAD_REQ, WGT_LOAD_WAIT: begin
          mem_phase_o = MEM_LOAD;
          dma_cmd_o.sys_addr = {2'b0, weight_addr};
          dma_cmd_o.byte_len = shape.wgt_per_oc;
          dma_cmd_o.space = SPACE_WGT;
          dma_cmd_valid_o = state == WGT_LOAD_REQ;
          dma_rsp_ready_o = state == WGT_LOAD_WAIT;
        end
        OFM_STORE_REQ, OFM_STORE_WAIT: begin
          mem_phase_o = MEM_STORE;
          dma_cmd_o.write = 1'b1;
          dma_cmd_o.sys_addr = {2'b0, cfg.dst_addr};
          dma_cmd_o.byte_len = shape.ofm_bytes;
          dma_cmd_o.space = SPACE_OFM;
          dma_cmd_valid_o = state == OFM_STORE_REQ;
          dma_rsp_ready_o = state == OFM_STORE_WAIT;
        end
        OC_INIT, QP_WAIT, QP_CHECK, COMPUTE_REQ, COMPUTE_WAIT: mem_phase_o = MEM_COMPUTE;
        default: begin end
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      cfg <= '0;
      shape <= '0;
      qparam <= '0;
      oc <= '0;
      error_o <= '0;
    end else begin
      case (state)
        IDLE: if (start_valid_i) begin
          cfg <= start_cfg_i;
          shape <= '0;
          oc <= '0;
          error_o <= '0;
          state <= VALIDATE;
        end
        VALIDATE: begin
          if (check_ok_i) begin shape <= check_shape_i; state <= QP_LOAD_REQ; end
          else begin error_o <= check_error_i; state <= FAIL; end
        end
        QP_LOAD_REQ: if (dma_cmd_ready_i) state <= QP_LOAD_WAIT;
        IFM_LOAD_REQ: if (dma_cmd_ready_i) state <= IFM_LOAD_WAIT;
        WGT_LOAD_REQ: if (dma_cmd_ready_i) state <= WGT_LOAD_WAIT;
        OFM_STORE_REQ: if (dma_cmd_ready_i) state <= OFM_STORE_WAIT;
        QP_LOAD_WAIT, IFM_LOAD_WAIT, WGT_LOAD_WAIT, OFM_STORE_WAIT: begin
          if (dma_rsp_valid_i) begin
            if (dma_rsp_i.error || dma_rsp_i.internal_error) begin
              error_o.code <= dma_rsp_i.internal_error ? E_INTERNAL :
                              (state == OFM_STORE_WAIT ? E_DMA_WRITE : E_DMA_READ);
              error_o.addr <= dma_rsp_i.error_addr[31:0];
              state <= FAIL;
            end else begin
              case (state)
                QP_LOAD_WAIT: state <= IFM_LOAD_REQ;
                IFM_LOAD_WAIT: state <= OC_INIT;
                WGT_LOAD_WAIT: state <= COMPUTE_REQ;
                default: state <= SUCCESS;
              endcase
            end
          end
        end
        OC_INIT: state <= QP_WAIT;
        QP_WAIT: if (qp_rd_valid_i) begin qparam <= qp_rd_data_i; state <= QP_CHECK; end
        QP_CHECK: begin
          if (qp_error.code != E_NONE) begin error_o <= qp_error; state <= FAIL; end
          else state <= WGT_LOAD_REQ;
        end
        COMPUTE_REQ: if (compute_start_ready_i) state <= COMPUTE_WAIT;
        COMPUTE_WAIT: if (compute_rsp_valid_i) begin
          if (compute_rsp_error_i) begin
            error_o.code <= E_INTERNAL;
            error_o.addr <= '0;
            state <= FAIL;
          end else state <= NEXT_OC;
        end
        NEXT_OC: begin
          if ({1'b0, oc} + 9'd1 < {1'b0, cfg.out_c}) begin
            oc <= oc + 8'd1;
            state <= OC_INIT;
          end else state <= OFM_STORE_REQ;
        end
        SUCCESS, FAIL: state <= IDLE;
        default: begin
          error_o.code <= E_INTERNAL;
          error_o.addr <= '0;
          state <= FAIL;
        end
      endcase
    end
  end
  // synthesis translate_off
  engines_exclusive: assert property (@(posedge clk) disable iff (!rst_n)
    !(dma_cmd_valid_o && compute_start_valid_o))
    else $fatal(1, "DMA and compute requested together");
  dma_request_stable: assert property (@(posedge clk) disable iff (!rst_n)
    dma_cmd_valid_o && !dma_cmd_ready_i |=> dma_cmd_valid_o && $stable(dma_cmd_o))
    else $fatal(1, "Controller DMA request changed under backpressure");
  compute_request_stable: assert property (@(posedge clk) disable iff (!rst_n)
    compute_start_valid_o && !compute_start_ready_i |=> compute_start_valid_o &&
    $stable({compute_cfg_o, compute_shape_o, compute_oc_o, compute_qparam_o}))
    else $fatal(1, "Controller compute request changed under backpressure");
  // synthesis translate_on
endmodule
