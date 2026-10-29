// tinyNPU의 공통 설정과 메모리 및 전송 자료형을 정의한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
package tinynpu_pkg;
  parameter int NPU_ADDR_W = 34;
  localparam logic [1:0] OP_CONV_POOL = 2'd0, OP_FC = 2'd1;
  localparam logic [1:0] SPACE_IFM = 2'd0, SPACE_WGT = 2'd1,
                         SPACE_OFM = 2'd2, SPACE_QPARAM = 2'd3;
  localparam logic [7:0] E_NONE = 8'h00, E_OP = 8'h01, E_SHAPE = 8'h02,
                         E_RANGE = 8'h03, E_ALIGN = 8'h04, E_OVERLAP = 8'h05,
                         E_QPARAM = 8'h06, E_DMA_READ = 8'h07,
                         E_DMA_WRITE = 8'h08, E_INTERNAL = 8'h09;
  typedef struct packed {
    logic [1:0] op;
    logic relu;
    logic [31:0] src_addr, weight_addr, dst_addr, qparam_addr;
    logic [7:0] in_h, in_w, in_c, out_c, input_zero, output_zero;
  } npu_cfg_t;
  typedef struct packed {
    logic [7:0] out_h, out_w;
    logic [15:0] ifm_bytes, ofm_bytes, wgt_per_oc, wgt_bytes, qparam_bytes;
  } npu_shape_t;
  typedef struct packed {
    logic signed [31:0] weight_zero, multiplier;
    logic [31:0] right_shift;
  } npu_qparam_t;
  typedef struct packed {
    logic write;
    logic [NPU_ADDR_W-1:0] sys_addr;
    logic [15:0] byte_len;
    logic [1:0] space;
  } npu_dma_cmd_t;
  typedef struct packed {
    logic error, internal_error;
    logic [NPU_ADDR_W-1:0] error_addr;
    logic [15:0] bytes_done;
  } npu_dma_rsp_t;
  typedef struct packed {
    logic write;
    logic [NPU_ADDR_W-1:0] addr;
    logic [2:0] size, burst;
    logic [4:0] beats;
  } npu_burst_cmd_t;
  typedef struct packed {
    logic error, cmd_error;
    logic [NPU_ADDR_W-1:0] error_addr;
    logic [4:0] beats_done;
  } npu_burst_rsp_t;
  typedef struct packed {
    logic [7:0] code;
    logic [31:0] addr;
  } npu_error_t;
  typedef enum logic [1:0] {
    MEM_IDLE = 2'd0, MEM_LOAD = 2'd1, MEM_COMPUTE = 2'd2, MEM_STORE = 2'd3
  } npu_mem_phase_t;
endpackage
