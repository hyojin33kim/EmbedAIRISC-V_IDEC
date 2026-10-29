// 세 개의 필드 RAM에 채널별 양자화 파라미터를 보관한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_qparam_ram (
  input  logic clk, rst_n,
  input  logic wr_en_i,
  input  logic [8:0] wr_addr_i,
  input  logic [7:0] wr_data_i,
  input  logic rd_en_i,
  input  logic [4:0] rd_oc_i,
  output logic rd_valid_o,
  output tinynpu_pkg::npu_qparam_t rd_data_o
);
  logic [31:0] weight_zero [0:31];
  logic [31:0] multiplier [0:31];
  logic [31:0] right_shift [0:31];
  logic [8:0] channel, byte_in_record;
  assign channel = wr_addr_i / 9'd12;
  assign byte_in_record = wr_addr_i % 9'd12;
  always_ff @(posedge clk) begin
    if (rst_n && wr_en_i && wr_addr_i < 9'd384) begin
      case (byte_in_record[3:2])
        2'd0: weight_zero[channel[4:0]][8*wr_addr_i[1:0] +: 8] <= wr_data_i;
        2'd1: multiplier[channel[4:0]][8*wr_addr_i[1:0] +: 8] <= wr_data_i;
        2'd2: right_shift[channel[4:0]][8*wr_addr_i[1:0] +: 8] <= wr_data_i;
        default: begin end
      endcase
    end
    if (rst_n && rd_en_i) begin
      rd_data_o.weight_zero <= weight_zero[rd_oc_i];
      rd_data_o.multiplier <= multiplier[rd_oc_i];
      rd_data_o.right_shift <= right_shift[rd_oc_i];
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_valid_o <= 1'b0;
    else rd_valid_o <= rd_en_i;
  end
`ifndef SYNTHESIS
  a_no_read_write: assert property (@(posedge clk) disable iff (!rst_n) !(wr_en_i && rd_en_i)) else $fatal(1, "a_no_read_write");
  a_write_in_range: assert property (@(posedge clk) disable iff (!rst_n) wr_en_i |-> wr_addr_i < 9'd384) else $fatal(1, "a_write_in_range");
`endif
endmodule
