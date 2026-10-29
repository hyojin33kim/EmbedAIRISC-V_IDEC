// tinyNPU 설정 스냅샷과 완료 및 오류 상태와 인터럽트를 관리한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_csr import tinynpu_pkg::*; (
  input logic clk, rst_n,
  input logic reg_valid_i, reg_write_i, reg_commit_i,
  input logic [11:0] reg_offset_i,
  input logic [31:0] reg_wdata_i,
  output logic [31:0] reg_rdata_o,
  output logic reg_error_o,
  output logic start_valid_o,
  input logic start_ready_i,
  output npu_cfg_t start_cfg_o,
  input logic busy_i, done_event_i, error_event_i,
  input npu_error_t error_i,
  output logic irq_o
);
  npu_cfg_t shadow_cfg;
  logic done_flag, error_flag, busy;
  logic [1:0] irq_enable;
  npu_error_t last_error;
  logic [31:0] cycles;
  logic known, read_only, reserved_bad, busy_bad, start_accept;

  assign busy = busy_i || start_valid_o;
  assign irq_o = (done_flag && irq_enable[0]) || (error_flag && irq_enable[1]);
  assign start_accept = reg_valid_i && reg_write_i && reg_commit_i && !reg_error_o &&
                        reg_offset_i == 12'h008 && reg_wdata_i[0];

  always_comb begin
    reg_rdata_o = '0;
    known = 1'b1;
    read_only = 1'b0;
    reserved_bad = 1'b0;
    case (reg_offset_i)
      12'h000: begin reg_rdata_o = 32'h544e5055; read_only = 1'b1; end
      12'h004: begin reg_rdata_o = 32'h00010000; read_only = 1'b1; end
      12'h008: reserved_bad = |(reg_wdata_i & 32'hfffffffe);
      12'h00c: begin
        reg_rdata_o = {29'b0, error_flag, done_flag, busy};
        reserved_bad = |(reg_wdata_i & 32'hfffffff9);
      end
      12'h010: begin
        reg_rdata_o = {30'b0, irq_enable};
        reserved_bad = |(reg_wdata_i & 32'hfffffffc);
      end
      12'h014: begin reg_rdata_o = {24'b0, last_error.code}; read_only = 1'b1; end
      12'h018: begin reg_rdata_o = last_error.addr; read_only = 1'b1; end
      12'h01c: begin reg_rdata_o = cycles; read_only = 1'b1; end
      12'h020: begin
        reg_rdata_o = {23'b0, shadow_cfg.relu, 6'b0, shadow_cfg.op};
        reserved_bad = |(reg_wdata_i & 32'hfffffefc);
      end
      12'h024: reg_rdata_o = shadow_cfg.src_addr;
      12'h028: reg_rdata_o = shadow_cfg.weight_addr;
      12'h02c: reg_rdata_o = shadow_cfg.dst_addr;
      12'h030: reg_rdata_o = shadow_cfg.qparam_addr;
      12'h034: begin
        reg_rdata_o = {8'b0, shadow_cfg.in_c, shadow_cfg.in_w, shadow_cfg.in_h};
        reserved_bad = |reg_wdata_i[31:24];
      end
      12'h038: begin
        reg_rdata_o = {24'b0, shadow_cfg.out_c};
        reserved_bad = |reg_wdata_i[31:8];
      end
      12'h03c: begin
        reg_rdata_o = {16'b0, shadow_cfg.output_zero, shadow_cfg.input_zero};
        reserved_bad = |reg_wdata_i[31:16];
      end
      default: known = 1'b0;
    endcase
    busy_bad = busy && ((reg_offset_i == 12'h008 && reg_wdata_i[0]) ||
                       (reg_offset_i >= 12'h020 && reg_offset_i <= 12'h03c));
    reg_error_o = reg_valid_i && (!known ||
                  (reg_write_i && (read_only || reserved_bad || busy_bad)));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shadow_cfg <= '0;
      start_cfg_o <= '0;
      start_valid_o <= 1'b0;
      done_flag <= 1'b0;
      error_flag <= 1'b0;
      irq_enable <= '0;
      last_error <= '0;
      cycles <= '0;
    end else begin
      if (busy) cycles <= cycles + 32'd1;
      if (start_valid_o && start_ready_i) start_valid_o <= 1'b0;
      if (reg_valid_i && reg_write_i && reg_commit_i && !reg_error_o) begin
        case (reg_offset_i)
          12'h00c: begin
            if (reg_wdata_i[1]) done_flag <= 1'b0;
            if (reg_wdata_i[2]) begin error_flag <= 1'b0; last_error <= '0; end
          end
          12'h010: irq_enable <= reg_wdata_i[1:0];
          12'h020: begin shadow_cfg.op <= reg_wdata_i[1:0]; shadow_cfg.relu <= reg_wdata_i[8]; end
          12'h024: shadow_cfg.src_addr <= reg_wdata_i;
          12'h028: shadow_cfg.weight_addr <= reg_wdata_i;
          12'h02c: shadow_cfg.dst_addr <= reg_wdata_i;
          12'h030: shadow_cfg.qparam_addr <= reg_wdata_i;
          12'h034: begin
            shadow_cfg.in_h <= reg_wdata_i[7:0];
            shadow_cfg.in_w <= reg_wdata_i[15:8];
            shadow_cfg.in_c <= reg_wdata_i[23:16];
          end
          12'h038: shadow_cfg.out_c <= reg_wdata_i[7:0];
          12'h03c: begin
            shadow_cfg.input_zero <= reg_wdata_i[7:0];
            shadow_cfg.output_zero <= reg_wdata_i[15:8];
          end
          default: begin end
        endcase
      end
      if (start_accept) begin
        start_cfg_o <= shadow_cfg;
        start_valid_o <= 1'b1;
        done_flag <= 1'b0;
        error_flag <= 1'b0;
        last_error <= '0;
        cycles <= '0;
      end
      if (done_event_i) begin
        done_flag <= 1'b1;
        error_flag <= 1'b0;
      end
      if (error_event_i) begin
        done_flag <= 1'b0;
        error_flag <= 1'b1;
        last_error <= error_i;
      end
    end
  end
  // synthesis translate_off
  completion_exclusive: assert property (@(posedge clk) disable iff (!rst_n) !(done_event_i && error_event_i))
    else $error("Simultaneous tinyNPU completion events");
  // synthesis translate_on
endmodule
