// 외부 AHB 버스트와 내부 바이트 메모리 사이의 DMA 복사를 관리한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_dma #(
  parameter int ADDR_W = tinynpu_pkg::NPU_ADDR_W
) (
  input logic clk, rst_n,
  input logic cmd_valid_i,
  output logic cmd_ready_o,
  input tinynpu_pkg::npu_dma_cmd_t cmd_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output tinynpu_pkg::npu_dma_rsp_t rsp_o,
  output logic lm_req_valid_o,
  input logic lm_req_ready_i,
  output logic lm_req_write_o,
  output logic [1:0] lm_req_space_o,
  output logic [11:0] lm_req_addr_o,
  output logic [7:0] lm_req_wdata_o,
  input logic lm_rsp_valid_i,
  output logic lm_rsp_ready_o,
  input logic [7:0] lm_rsp_rdata_i,
  input logic lm_rsp_error_i,
  output logic [ADDR_W-1:0] m_HADDR,
  output logic [31:0] m_HWDATA,
  output logic [3:0] m_HWSTRB,
  output logic m_HWRITE, m_HMASTLOCK,
  output logic [2:0] m_HSIZE, m_HBURST,
  output logic [3:0] m_HPROT,
  output logic [1:0] m_HTRANS,
  input logic [31:0] m_HRDATA,
  input logic m_HREADY, m_HRESP
);
  import tinynpu_pkg::*;
  typedef enum logic [3:0] {
    IDLE, PLAN, READ_BURST_REQ, READ_BURST_WAIT, READ_COPY_REQ,
    READ_COPY_WAIT, WRITE_FILL_REQ, WRITE_FILL_WAIT,
    WRITE_BURST_REQ, WRITE_BURST_WAIT, RESP
  } state_t;
  state_t state_q;
  npu_dma_cmd_t command_q;
  npu_burst_cmd_t burst_q;
  npu_burst_rsp_t burst_rsp;
  logic burst_valid, burst_ready, burst_rsp_valid, burst_rsp_ready;
  logic [ADDR_W-1:0] cursor_q;
  logic [15:0] remaining_q, offset_q, done_q;
  logic [6:0] chunk_q, byte_q;
  logic plan_valid;
  logic [2:0] plan_size, plan_burst;
  logic [4:0] plan_beats;
  logic [6:0] plan_bytes;
  logic command_ok;
  logic [15:0] capacity, local_offset;
  logic [ADDR_W:0] command_end;
  logic [ADDR_W-1:0] current_byte_addr;
  logic [5:0] stage_byte_addr;
  logic stage_byte_we, stage_word_we;
  logic [7:0] stage_byte_data;
  logic [3:0] stage_word_windex, stage_word_rindex;
  logic [31:0] stage_word_wdata, stage_word_rdata;
  logic [15:0] completed_burst_bytes;
  int unsigned stage_offset;

  always_comb begin
    capacity = '0;
    case (cmd_i.space)
      SPACE_IFM, SPACE_OFM: capacity = 16'd2048;
      SPACE_WGT: capacity = 16'd512;
      SPACE_QPARAM: capacity = 16'd384;
      default: capacity = '0;
    endcase
    command_end = {1'b0, cmd_i.sys_addr} + {{(ADDR_W-15){1'b0}}, cmd_i.byte_len};
    command_ok = cmd_i.byte_len != 0 && cmd_i.byte_len <= capacity &&
                 (cmd_i.write ? cmd_i.space == SPACE_OFM : cmd_i.space != SPACE_OFM) &&
                 cmd_i.sys_addr >= ADDR_W'('h80000000) &&
                 command_end <= (ADDR_W+1)'('h88000000) && !command_end[ADDR_W];
    local_offset = offset_q + {9'b0, byte_q};
    current_byte_addr = cursor_q + {{(ADDR_W-7){1'b0}}, byte_q};
    stage_offset = ((int'(byte_q) >> burst_q.size) << 2) + int'(current_byte_addr[1:0]);
    stage_byte_addr = stage_offset[5:0];
    completed_burst_bytes = {11'b0, burst_rsp.beats_done} << burst_q.size;
  end

  assign cmd_ready_o = rst_n && state_q == IDLE;
  assign rsp_valid_o = rst_n && state_q == RESP;
  assign burst_valid = state_q == READ_BURST_REQ || state_q == WRITE_BURST_REQ;
  assign burst_rsp_ready = state_q == READ_BURST_WAIT || state_q == WRITE_BURST_WAIT;
  assign lm_req_valid_o = rst_n && (state_q == READ_COPY_REQ || state_q == WRITE_FILL_REQ);
  assign lm_req_write_o = state_q == READ_COPY_REQ;
  assign lm_req_space_o = command_q.space;
  assign lm_req_addr_o = local_offset[11:0];
  assign lm_req_wdata_o = stage_byte_data;
  assign lm_rsp_ready_o = rst_n && (state_q == READ_COPY_WAIT || state_q == WRITE_FILL_WAIT);
  assign stage_byte_we = state_q == WRITE_FILL_WAIT && lm_rsp_valid_i && !lm_rsp_error_i;

  tinynpu_dma_plan #(.ADDR_W(ADDR_W)) u_plan (
    .addr_i(cursor_q), .remaining_i(remaining_q), .valid_o(plan_valid),
    .size_o(plan_size), .burst_o(plan_burst), .beats_o(plan_beats), .chunk_bytes_o(plan_bytes)
  );
  tinynpu_dma_stage u_stage (
    .clk, .rst_n, .byte_wr_en_i(stage_byte_we), .byte_wr_addr_i(stage_byte_addr),
    .byte_wr_data_i(lm_rsp_rdata_i), .byte_rd_addr_i(stage_byte_addr), .byte_rd_data_o(stage_byte_data),
    .word_wr_en_i(stage_word_we), .word_wr_index_i(stage_word_windex), .word_wr_data_i(stage_word_wdata),
    .word_rd_index_i(stage_word_rindex), .word_rd_data_o(stage_word_rdata)
  );
  tinynpu_ahb_master #(.ADDR_W(ADDR_W)) u_master (
    .clk, .rst_n, .cmd_valid_i(burst_valid), .cmd_ready_o(burst_ready), .cmd_i(burst_q),
    .rsp_valid_o(burst_rsp_valid), .rsp_ready_i(burst_rsp_ready), .rsp_o(burst_rsp),
    .stage_word_rd_index_o(stage_word_rindex), .stage_word_rd_data_i(stage_word_rdata),
    .stage_word_wr_en_o(stage_word_we), .stage_word_wr_index_o(stage_word_windex),
    .stage_word_wr_data_o(stage_word_wdata),
    .m_HADDR, .m_HWDATA, .m_HWSTRB, .m_HWRITE, .m_HMASTLOCK,
    .m_HSIZE, .m_HBURST, .m_HPROT, .m_HTRANS, .m_HRDATA, .m_HREADY, .m_HRESP
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= IDLE;
      command_q <= '0;
      burst_q <= '0;
      cursor_q <= '0;
      remaining_q <= '0;
      offset_q <= '0;
      done_q <= '0;
      chunk_q <= '0;
      byte_q <= '0;
      rsp_o <= '0;
    end else begin
      case (state_q)
        IDLE: if (cmd_valid_i) begin
          command_q <= cmd_i;
          cursor_q <= cmd_i.sys_addr;
          remaining_q <= cmd_i.byte_len;
          offset_q <= '0;
          done_q <= '0;
          byte_q <= '0;
          rsp_o <= '0;
          if (command_ok) state_q <= PLAN;
          else begin
            rsp_o.error <= 1'b1;
            rsp_o.internal_error <= 1'b1;
            rsp_o.error_addr <= cmd_i.sys_addr;
            state_q <= RESP;
          end
        end
        PLAN: begin
          if (plan_valid) begin
            burst_q.write <= command_q.write;
            burst_q.addr <= cursor_q;
            burst_q.size <= plan_size;
            burst_q.burst <= plan_burst;
            burst_q.beats <= plan_beats;
            chunk_q <= plan_bytes;
            byte_q <= '0;
            state_q <= command_q.write ? WRITE_FILL_REQ : READ_BURST_REQ;
          end else begin
            rsp_o.error <= 1'b1;
            rsp_o.internal_error <= 1'b1;
            rsp_o.error_addr <= cursor_q;
            rsp_o.bytes_done <= done_q;
            state_q <= RESP;
          end
        end
        READ_BURST_REQ: if (burst_ready) state_q <= READ_BURST_WAIT;
        READ_BURST_WAIT: if (burst_rsp_valid) begin
          if (burst_rsp.error) begin
            rsp_o.error <= 1'b1;
            rsp_o.internal_error <= burst_rsp.cmd_error;
            rsp_o.error_addr <= burst_rsp.error_addr;
            rsp_o.bytes_done <= done_q;
            state_q <= RESP;
          end else state_q <= READ_COPY_REQ;
        end
        READ_COPY_REQ: if (lm_req_ready_i) state_q <= READ_COPY_WAIT;
        READ_COPY_WAIT: if (lm_rsp_valid_i) begin
          if (lm_rsp_error_i) begin
            rsp_o.error <= 1'b1;
            rsp_o.internal_error <= 1'b1;
            rsp_o.error_addr <= current_byte_addr;
            rsp_o.bytes_done <= done_q;
            state_q <= RESP;
          end else begin
            done_q <= done_q + 1'b1;
            if (byte_q + 1'b1 == chunk_q) begin
              cursor_q <= cursor_q + {{(ADDR_W-7){1'b0}}, chunk_q};
              offset_q <= offset_q + {9'b0, chunk_q};
              remaining_q <= remaining_q - {9'b0, chunk_q};
              if (remaining_q == {9'b0, chunk_q}) begin
                rsp_o.bytes_done <= done_q + 1'b1;
                state_q <= RESP;
              end else state_q <= PLAN;
            end else begin
              byte_q <= byte_q + 1'b1;
              state_q <= READ_COPY_REQ;
            end
          end
        end
        WRITE_FILL_REQ: if (lm_req_ready_i) state_q <= WRITE_FILL_WAIT;
        WRITE_FILL_WAIT: if (lm_rsp_valid_i) begin
          if (lm_rsp_error_i) begin
            rsp_o.error <= 1'b1;
            rsp_o.internal_error <= 1'b1;
            rsp_o.error_addr <= current_byte_addr;
            rsp_o.bytes_done <= done_q;
            state_q <= RESP;
          end else if (byte_q + 1'b1 == chunk_q) state_q <= WRITE_BURST_REQ;
          else begin
            byte_q <= byte_q + 1'b1;
            state_q <= WRITE_FILL_REQ;
          end
        end
        WRITE_BURST_REQ: if (burst_ready) state_q <= WRITE_BURST_WAIT;
        WRITE_BURST_WAIT: if (burst_rsp_valid) begin
          if (burst_rsp.error) begin
            rsp_o.error <= 1'b1;
            rsp_o.internal_error <= burst_rsp.cmd_error;
            rsp_o.error_addr <= burst_rsp.error_addr;
            rsp_o.bytes_done <= done_q + completed_burst_bytes;
            state_q <= RESP;
          end else begin
            done_q <= done_q + {9'b0, chunk_q};
            cursor_q <= cursor_q + {{(ADDR_W-7){1'b0}}, chunk_q};
            offset_q <= offset_q + {9'b0, chunk_q};
            remaining_q <= remaining_q - {9'b0, chunk_q};
            if (remaining_q == {9'b0, chunk_q}) begin
              rsp_o.bytes_done <= done_q + {9'b0, chunk_q};
              state_q <= RESP;
            end else state_q <= PLAN;
          end
        end
        RESP: if (rsp_ready_i) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end

  // synthesis translate_off
  initial if (ADDR_W != NPU_ADDR_W)
    $fatal(1, "DMA address width must match package");
  dma_response_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(rsp_o))
    else $fatal(1, "DMA response changed under backpressure");
  dma_request_stable: assert property (@(posedge clk) disable iff (!rst_n)
    lm_req_valid_o && !lm_req_ready_i |=> lm_req_valid_o &&
      $stable({lm_req_write_o, lm_req_space_o, lm_req_addr_o, lm_req_wdata_o}))
    else $fatal(1, "DMA local request changed under backpressure");
  // synthesis translate_on
endmodule
