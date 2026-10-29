// 주소와 데이터 단계를 분리하여 모든 AHB-Lite 버스트를 실행한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_ahb_master #(
  parameter int ADDR_W = tinynpu_pkg::NPU_ADDR_W
) (
  input logic clk, rst_n,
  input logic cmd_valid_i,
  output logic cmd_ready_o,
  input tinynpu_pkg::npu_burst_cmd_t cmd_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output tinynpu_pkg::npu_burst_rsp_t rsp_o,
  output logic [3:0] stage_word_rd_index_o,
  input logic [31:0] stage_word_rd_data_i,
  output logic stage_word_wr_en_o,
  output logic [3:0] stage_word_wr_index_o,
  output logic [31:0] stage_word_wr_data_o,
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
  npu_burst_cmd_t command_q;
  logic active_q, a_valid_q, d_valid_q;
  logic [4:0] a_index_q, d_index_q, done_q;
  logic [ADDR_W-1:0] a_addr_q, d_addr_q;
  logic [2:0] d_size_q;
  logic command_ok;
  logic [ADDR_W:0] end_byte;
  logic [ADDR_W-1:0] beat_mask, wrap_mask, next_addr;
  logic [3:0] lane_mask;

  always_comb begin
    beat_mask = ({{(ADDR_W-1){1'b0}}, 1'b1} << cmd_i.size) - 1'b1;
    end_byte = {1'b0, cmd_i.addr} +
               (({{(ADDR_W-4){1'b0}}, cmd_i.beats}) << cmd_i.size) - 1'b1;
    command_ok = cmd_i.size <= 2 && cmd_i.beats >= 1 && cmd_i.beats <= 16 &&
                 (cmd_i.addr & beat_mask) == 0;
    case (cmd_i.burst)
      3'b000: command_ok = command_ok && cmd_i.beats == 1;
      3'b010, 3'b011: command_ok = command_ok && cmd_i.beats == 4;
      3'b100, 3'b101: command_ok = command_ok && cmd_i.beats == 8;
      3'b110, 3'b111: command_ok = command_ok && cmd_i.beats == 16;
      default: command_ok = command_ok && cmd_i.burst == 3'b001;
    endcase
    if (cmd_i.burst[0] || cmd_i.burst == 0) begin
      command_ok = command_ok && !end_byte[ADDR_W] &&
                   end_byte[ADDR_W-1:10] == cmd_i.addr[ADDR_W-1:10];
    end
    wrap_mask = (({{(ADDR_W-5){1'b0}}, command_q.beats}) << command_q.size) - 1'b1;
    next_addr = a_addr_q + ({{(ADDR_W-1){1'b0}}, 1'b1} << command_q.size);
    if (!command_q.burst[0] && command_q.burst != 0)
      next_addr = (command_q.addr & ~wrap_mask) | (next_addr & wrap_mask);
  end

  assign cmd_ready_o = rst_n && !active_q && !rsp_valid_o;
  assign m_HADDR = a_addr_q;
  assign m_HTRANS = rst_n && a_valid_q ? (a_index_q == 0 ? 2'b10 : 2'b11) : 2'b00;
  assign m_HWRITE = rst_n && active_q && command_q.write;
  assign m_HSIZE = command_q.size;
  assign m_HBURST = command_q.burst;
  assign m_HPROT = 4'b0011;
  assign m_HMASTLOCK = 1'b0;
  assign stage_word_rd_index_o = d_index_q[3:0];
  assign stage_word_wr_index_o = d_index_q[3:0];
  assign stage_word_wr_data_o = m_HRDATA;
  assign stage_word_wr_en_o = rst_n && d_valid_q && m_HREADY && !m_HRESP && !command_q.write;

  always_comb begin
    lane_mask = 4'b0000;
    case (d_size_q)
      3'd0: lane_mask = 4'b0001 << d_addr_q[1:0];
      3'd1: lane_mask = 4'b0011 << d_addr_q[1:0];
      3'd2: lane_mask = 4'b1111;
      default: lane_mask = 4'b0000;
    endcase
    m_HWSTRB = rst_n && d_valid_q && command_q.write ? lane_mask : 4'b0000;
    m_HWDATA = 32'b0;
    for (int lane = 0; lane < 4; lane++)
      if (m_HWSTRB[lane]) m_HWDATA[8*lane +: 8] = stage_word_rd_data_i[8*lane +: 8];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      command_q <= '0;
      active_q <= 1'b0;
      a_valid_q <= 1'b0;
      d_valid_q <= 1'b0;
      a_index_q <= '0;
      d_index_q <= '0;
      done_q <= '0;
      a_addr_q <= '0;
      d_addr_q <= '0;
      d_size_q <= '0;
      rsp_valid_o <= 1'b0;
      rsp_o <= '0;
    end else begin
      if (rsp_valid_o && rsp_ready_i) rsp_valid_o <= 1'b0;
      if (cmd_valid_i && cmd_ready_o) begin
        command_q <= cmd_i;
        done_q <= '0;
        a_index_q <= '0;
        d_valid_q <= 1'b0;
        rsp_o <= '0;
        if (command_ok) begin
          active_q <= 1'b1;
          a_valid_q <= 1'b1;
          a_addr_q <= cmd_i.addr;
        end else begin
          rsp_valid_o <= 1'b1;
          rsp_o.error <= 1'b1;
          rsp_o.cmd_error <= 1'b1;
          rsp_o.error_addr <= cmd_i.addr;
        end
      end else if (active_q) begin
        if (d_valid_q && !m_HREADY && m_HRESP) a_valid_q <= 1'b0;
        if (m_HREADY) begin
          if (d_valid_q && m_HRESP) begin
            active_q <= 1'b0;
            a_valid_q <= 1'b0;
            d_valid_q <= 1'b0;
            rsp_valid_o <= 1'b1;
            rsp_o.error <= 1'b1;
            rsp_o.cmd_error <= 1'b0;
            rsp_o.error_addr <= d_addr_q;
            rsp_o.beats_done <= done_q;
          end else begin
            d_valid_q <= a_valid_q;
            if (a_valid_q) begin
              d_index_q <= a_index_q;
              d_addr_q <= a_addr_q;
              d_size_q <= command_q.size;
              if (a_index_q + 1'b1 == command_q.beats) a_valid_q <= 1'b0;
              else begin
                a_index_q <= a_index_q + 1'b1;
                a_addr_q <= next_addr;
              end
            end
            if (d_valid_q) begin
              done_q <= done_q + 1'b1;
              if (d_index_q + 1'b1 == command_q.beats) begin
                active_q <= 1'b0;
                rsp_valid_o <= 1'b1;
                rsp_o.beats_done <= done_q + 1'b1;
              end
            end
          end
        end
      end
    end
  end

  // synthesis translate_off
  initial if (ADDR_W != NPU_ADDR_W)
    $fatal(1, "AHB master address width must match package");
  master_wait_stable: assert property (@(posedge clk) disable iff (!rst_n)
    active_q && !m_HREADY && !m_HRESP |=>
      $stable({m_HADDR, m_HTRANS, m_HWRITE, m_HSIZE, m_HBURST, m_HWDATA, m_HWSTRB}))
    else $fatal(1, "AHB master changed a normal stalled transfer");
  master_response_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(rsp_o))
    else $fatal(1, "AHB master response changed under backpressure");
  master_stage_in_range: assert property (@(posedge clk) disable iff (!rst_n)
    d_valid_q |-> d_index_q < 16)
    else $fatal(1, "AHB stage index exceeded storage");
  // synthesis translate_on
endmodule
