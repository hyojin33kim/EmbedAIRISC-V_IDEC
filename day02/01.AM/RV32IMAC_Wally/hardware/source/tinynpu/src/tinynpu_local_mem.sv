// DMA와 연산기의 소유권 및 주소를 검사하고 내부 RAM을 연결한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_local_mem (
  input  logic clk, rst_n,
  input  tinynpu_pkg::npu_mem_phase_t phase_i,
  input  logic dma_req_valid_i,
  output logic dma_req_ready_o,
  input  logic dma_req_write_i,
  input  logic [1:0] dma_req_space_i,
  input  logic [11:0] dma_req_addr_i,
  input  logic [7:0] dma_req_wdata_i,
  output logic dma_rsp_valid_o,
  input  logic dma_rsp_ready_i,
  output logic [7:0] dma_rsp_rdata_o,
  output logic dma_rsp_error_o,
  input  logic ifm_rd_en_i, wgt_rd_en_i,
  input  logic [11:0] ifm_rd_addr_i, wgt_rd_addr_i,
  output logic ifm_rd_valid_o, wgt_rd_valid_o,
  output logic [7:0] ifm_rd_data_o, wgt_rd_data_o,
  input  logic ofm_wr_valid_i,
  output logic ofm_wr_ready_o,
  input  logic [11:0] ofm_wr_addr_i,
  input  logic [7:0] ofm_wr_data_i,
  input  logic qp_rd_en_i,
  input  logic [4:0] qp_rd_oc_i,
  output logic qp_rd_valid_o,
  output tinynpu_pkg::npu_qparam_t qp_rd_data_o,
  output logic compute_fault_o
);
  import tinynpu_pkg::*;
  logic dma_accept, dma_legal, dma_read_rsp;
  logic ifm_write, wgt_write, qp_write, ofm_read;
  logic ifm_read, wgt_read, qp_read, ofm_write;
  logic ofm_read_valid;
  logic [7:0] ofm_read_data;
  assign dma_req_ready_o = rst_n && !dma_rsp_valid_o;
  assign dma_accept = dma_req_valid_i && dma_req_ready_o;
  assign ofm_wr_ready_o = rst_n;
  assign ifm_read = rst_n && phase_i == MEM_COMPUTE && ifm_rd_en_i && ifm_rd_addr_i < 12'd2048;
  assign wgt_read = rst_n && phase_i == MEM_COMPUTE && wgt_rd_en_i && wgt_rd_addr_i < 12'd512;
  assign qp_read = rst_n && phase_i == MEM_COMPUTE && qp_rd_en_i;
  assign ofm_write = rst_n && phase_i == MEM_COMPUTE && ofm_wr_valid_i && ofm_wr_addr_i < 12'd2048;
  always_comb begin
    dma_legal = 1'b0;
    if (phase_i == MEM_LOAD && dma_req_write_i) begin
      case (dma_req_space_i)
        SPACE_IFM: dma_legal = dma_req_addr_i < 12'd2048;
        SPACE_WGT: dma_legal = dma_req_addr_i < 12'd512;
        SPACE_QPARAM: dma_legal = dma_req_addr_i < 12'd384;
        default: dma_legal = 1'b0;
      endcase
    end else if (phase_i == MEM_STORE && !dma_req_write_i)
      dma_legal = dma_req_space_i == SPACE_OFM && dma_req_addr_i < 12'd2048;
    ifm_write = dma_accept && dma_legal && dma_req_space_i == SPACE_IFM;
    wgt_write = dma_accept && dma_legal && dma_req_space_i == SPACE_WGT;
    qp_write = dma_accept && dma_legal && dma_req_space_i == SPACE_QPARAM;
    ofm_read = dma_accept && dma_legal && dma_req_space_i == SPACE_OFM;
  end
  assign dma_rsp_rdata_o = dma_read_rsp && !dma_rsp_error_o ? ofm_read_data : 8'd0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_rsp_valid_o <= 1'b0;
      dma_rsp_error_o <= 1'b0;
      dma_read_rsp <= 1'b0;
      compute_fault_o <= 1'b0;
    end else begin
      compute_fault_o <= (ifm_rd_en_i && !ifm_read) || (wgt_rd_en_i && !wgt_read)
                         || (qp_rd_en_i && !qp_read) || (ofm_wr_valid_i && !ofm_write);
      if (dma_rsp_valid_o && dma_rsp_ready_i) dma_rsp_valid_o <= 1'b0;
      if (dma_accept) begin
        dma_rsp_valid_o <= 1'b1;
        dma_rsp_error_o <= !dma_legal;
        dma_read_rsp <= dma_legal && !dma_req_write_i;
      end
    end
  end
  tinynpu_data_ram #(.BYTES(2048)) u_ifm (
    .clk, .rst_n, .wr_en_i(ifm_write), .wr_addr_i(dma_req_addr_i[10:0]), .wr_data_i(dma_req_wdata_i),
    .rd_en_i(ifm_read), .rd_addr_i(ifm_rd_addr_i[10:0]), .rd_valid_o(ifm_rd_valid_o), .rd_data_o(ifm_rd_data_o)
  );
  tinynpu_data_ram #(.BYTES(512)) u_wgt (
    .clk, .rst_n, .wr_en_i(wgt_write), .wr_addr_i(dma_req_addr_i[8:0]), .wr_data_i(dma_req_wdata_i),
    .rd_en_i(wgt_read), .rd_addr_i(wgt_rd_addr_i[8:0]), .rd_valid_o(wgt_rd_valid_o), .rd_data_o(wgt_rd_data_o)
  );
  tinynpu_data_ram #(.BYTES(2048)) u_ofm (
    .clk, .rst_n, .wr_en_i(ofm_write), .wr_addr_i(ofm_wr_addr_i[10:0]), .wr_data_i(ofm_wr_data_i),
    .rd_en_i(ofm_read), .rd_addr_i(dma_req_addr_i[10:0]), .rd_valid_o(ofm_read_valid), .rd_data_o(ofm_read_data)
  );
  tinynpu_qparam_ram u_qparam (
    .clk, .rst_n, .wr_en_i(qp_write), .wr_addr_i(dma_req_addr_i[8:0]), .wr_data_i(dma_req_wdata_i),
    .rd_en_i(qp_read), .rd_oc_i(qp_rd_oc_i), .rd_valid_o(qp_rd_valid_o), .rd_data_o(qp_rd_data_o)
  );
`ifndef SYNTHESIS
  a_dma_response_stable: assert property (@(posedge clk) disable iff (!rst_n)
    dma_rsp_valid_o && !dma_rsp_ready_i |=> dma_rsp_valid_o && $stable({dma_rsp_rdata_o, dma_rsp_error_o})) else $fatal(1, "a_dma_response_stable");
  a_dma_read_latency: assert property (@(posedge clk) disable iff (!rst_n)
    ofm_read |=> ofm_read_valid && dma_rsp_valid_o) else $fatal(1, "a_dma_read_latency");
`endif
endmodule
