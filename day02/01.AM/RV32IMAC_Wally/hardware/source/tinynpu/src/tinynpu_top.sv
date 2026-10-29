// tinyNPU의 AHB 제어부와 DMA 및 단일 MAC 연산 계층을 연결한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_top import tinynpu_pkg::*; #(
  parameter int ADDR_W = NPU_ADDR_W
) (
  input logic HCLK, HRESETn,
  input logic s_HSEL,
  input logic [ADDR_W-1:0] s_HADDR,
  input logic [31:0] s_HWDATA,
  input logic [3:0] s_HWSTRB,
  input logic s_HWRITE,
  input logic [2:0] s_HSIZE, s_HBURST,
  input logic [3:0] s_HPROT,
  input logic [1:0] s_HTRANS,
  input logic s_HMASTLOCK, s_HREADY,
  output logic [31:0] s_HRDATA,
  output logic s_HRESP, s_HREADYOUT,
  output logic [ADDR_W-1:0] m_HADDR,
  output logic [31:0] m_HWDATA,
  output logic [3:0] m_HWSTRB,
  output logic m_HWRITE,
  output logic [2:0] m_HSIZE, m_HBURST,
  output logic [3:0] m_HPROT,
  output logic [1:0] m_HTRANS,
  output logic m_HMASTLOCK,
  input logic [31:0] m_HRDATA,
  input logic m_HREADY, m_HRESP,
  output logic irq_o
);
  logic reg_valid, reg_write, reg_commit, reg_error;
  logic [11:0] reg_offset;
  logic [31:0] reg_wdata, reg_rdata;
  logic start_valid, start_ready, busy, done_event, error_event, check_ok;
  npu_cfg_t start_cfg, check_cfg, compute_cfg;
  npu_shape_t check_shape, compute_shape;
  npu_error_t controller_error, check_error;
  npu_mem_phase_t mem_phase;
  logic dma_cmd_valid, dma_cmd_ready, dma_rsp_valid, dma_rsp_ready;
  npu_dma_cmd_t dma_cmd;
  npu_dma_rsp_t dma_rsp;
  logic qp_rd_en, qp_rd_valid;
  logic [4:0] qp_rd_oc;
  npu_qparam_t qp_rd_data, compute_qparam;
  logic compute_start_valid, compute_start_ready, compute_rsp_valid;
  logic compute_rsp_ready, compute_rsp_error;
  logic [7:0] compute_oc;
  logic lm_req_valid, lm_req_ready, lm_req_write, lm_rsp_valid, lm_rsp_ready, lm_rsp_error;
  logic [1:0] lm_req_space;
  logic [11:0] lm_req_addr;
  logic [7:0] lm_req_wdata, lm_rsp_rdata;
  logic ifm_rd_en, wgt_rd_en, ifm_rd_valid, wgt_rd_valid;
  logic [11:0] ifm_rd_addr, wgt_rd_addr, ofm_wr_addr;
  logic [7:0] ifm_rd_data, wgt_rd_data, ofm_wr_data;
  logic ofm_wr_valid, ofm_wr_ready, compute_fault;

  tinynpu_ahb_slave #(.ADDR_W(ADDR_W)) slave (
    .clk(HCLK), .rst_n(HRESETn), .s_HSEL, .s_HWRITE, .s_HREADY, .s_HADDR,
    .s_HSIZE, .s_HTRANS, .s_HWDATA, .s_HWSTRB, .s_HRDATA, .s_HRESP, .s_HREADYOUT,
    .reg_valid_o(reg_valid), .reg_write_o(reg_write), .reg_offset_o(reg_offset),
    .reg_wdata_o(reg_wdata), .reg_commit_o(reg_commit),
    .reg_rdata_i(reg_rdata), .reg_error_i(reg_error)
  );
  tinynpu_csr csr (
    .clk(HCLK), .rst_n(HRESETn), .reg_valid_i(reg_valid), .reg_write_i(reg_write),
    .reg_commit_i(reg_commit), .reg_offset_i(reg_offset), .reg_wdata_i(reg_wdata),
    .reg_rdata_o(reg_rdata), .reg_error_o(reg_error),
    .start_valid_o(start_valid), .start_ready_i(start_ready), .start_cfg_o(start_cfg),
    .busy_i(busy), .done_event_i(done_event), .error_event_i(error_event),
    .error_i(controller_error), .irq_o
  );
  tinynpu_cfg_check cfg_check (
    .cfg_i(check_cfg), .ok_o(check_ok), .shape_o(check_shape), .error_o(check_error)
  );
  tinynpu_controller controller (
    .clk(HCLK), .rst_n(HRESETn), .start_valid_i(start_valid), .start_ready_o(start_ready),
    .start_cfg_i(start_cfg), .check_cfg_o(check_cfg), .check_ok_i(check_ok),
    .check_shape_i(check_shape), .check_error_i(check_error), .busy_o(busy),
    .done_event_o(done_event), .error_event_o(error_event), .error_o(controller_error),
    .mem_phase_o(mem_phase), .dma_cmd_valid_o(dma_cmd_valid), .dma_cmd_ready_i(dma_cmd_ready),
    .dma_cmd_o(dma_cmd), .dma_rsp_valid_i(dma_rsp_valid), .dma_rsp_ready_o(dma_rsp_ready),
    .dma_rsp_i(dma_rsp), .qp_rd_en_o(qp_rd_en), .qp_rd_oc_o(qp_rd_oc),
    .qp_rd_valid_i(qp_rd_valid), .qp_rd_data_i(qp_rd_data),
    .compute_start_valid_o(compute_start_valid), .compute_start_ready_i(compute_start_ready),
    .compute_cfg_o(compute_cfg), .compute_shape_o(compute_shape), .compute_oc_o(compute_oc),
    .compute_qparam_o(compute_qparam), .compute_rsp_valid_i(compute_rsp_valid),
    .compute_rsp_ready_o(compute_rsp_ready), .compute_rsp_error_i(compute_rsp_error)
  );
  tinynpu_dma #(.ADDR_W(ADDR_W)) dma (
    .clk(HCLK), .rst_n(HRESETn), .cmd_valid_i(dma_cmd_valid), .cmd_ready_o(dma_cmd_ready),
    .cmd_i(dma_cmd), .rsp_valid_o(dma_rsp_valid), .rsp_ready_i(dma_rsp_ready), .rsp_o(dma_rsp),
    .lm_req_valid_o(lm_req_valid), .lm_req_ready_i(lm_req_ready), .lm_req_write_o(lm_req_write),
    .lm_req_space_o(lm_req_space), .lm_req_addr_o(lm_req_addr), .lm_req_wdata_o(lm_req_wdata),
    .lm_rsp_valid_i(lm_rsp_valid), .lm_rsp_ready_o(lm_rsp_ready), .lm_rsp_rdata_i(lm_rsp_rdata),
    .lm_rsp_error_i(lm_rsp_error), .m_HADDR, .m_HWDATA, .m_HWSTRB, .m_HWRITE,
    .m_HMASTLOCK, .m_HSIZE, .m_HBURST, .m_HPROT, .m_HTRANS, .m_HRDATA, .m_HREADY, .m_HRESP
  );
  tinynpu_local_mem local_mem (
    .clk(HCLK), .rst_n(HRESETn), .phase_i(mem_phase),
    .dma_req_valid_i(lm_req_valid), .dma_req_ready_o(lm_req_ready), .dma_req_write_i(lm_req_write),
    .dma_req_space_i(lm_req_space), .dma_req_addr_i(lm_req_addr), .dma_req_wdata_i(lm_req_wdata),
    .dma_rsp_valid_o(lm_rsp_valid), .dma_rsp_ready_i(lm_rsp_ready), .dma_rsp_rdata_o(lm_rsp_rdata),
    .dma_rsp_error_o(lm_rsp_error), .ifm_rd_en_i(ifm_rd_en), .wgt_rd_en_i(wgt_rd_en),
    .ifm_rd_addr_i(ifm_rd_addr), .wgt_rd_addr_i(wgt_rd_addr),
    .ifm_rd_valid_o(ifm_rd_valid), .wgt_rd_valid_o(wgt_rd_valid),
    .ifm_rd_data_o(ifm_rd_data), .wgt_rd_data_o(wgt_rd_data),
    .ofm_wr_valid_i(ofm_wr_valid), .ofm_wr_ready_o(ofm_wr_ready),
    .ofm_wr_addr_i(ofm_wr_addr), .ofm_wr_data_i(ofm_wr_data),
    .qp_rd_en_i(qp_rd_en), .qp_rd_oc_i(qp_rd_oc), .qp_rd_valid_o(qp_rd_valid),
    .qp_rd_data_o(qp_rd_data), .compute_fault_o(compute_fault)
  );
  tinynpu_compute compute (
    .clk(HCLK), .rst_n(HRESETn), .start_valid_i(compute_start_valid),
    .start_ready_o(compute_start_ready), .cfg_i(compute_cfg), .shape_i(compute_shape),
    .oc_i(compute_oc), .qparam_i(compute_qparam), .rsp_valid_o(compute_rsp_valid),
    .rsp_ready_i(compute_rsp_ready), .rsp_error_o(compute_rsp_error),
    .ifm_rd_en_o(ifm_rd_en), .wgt_rd_en_o(wgt_rd_en),
    .ifm_rd_addr_o(ifm_rd_addr), .wgt_rd_addr_o(wgt_rd_addr),
    .ifm_rd_valid_i(ifm_rd_valid), .wgt_rd_valid_i(wgt_rd_valid),
    .ifm_rd_data_i(ifm_rd_data), .wgt_rd_data_i(wgt_rd_data),
    .ofm_wr_valid_o(ofm_wr_valid), .ofm_wr_ready_i(ofm_wr_ready),
    .ofm_wr_addr_o(ofm_wr_addr), .ofm_wr_data_o(ofm_wr_data), .mem_fault_i(compute_fault)
  );
  // synthesis translate_off
  initial begin
    address_width: assert (ADDR_W == NPU_ADDR_W) else $fatal(1, "tinyNPU requires 34-bit addresses");
  end
  // synthesis translate_on
endmodule
