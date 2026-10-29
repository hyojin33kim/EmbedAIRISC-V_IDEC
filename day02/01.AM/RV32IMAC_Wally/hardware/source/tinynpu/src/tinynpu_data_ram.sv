// 바이트 쓰기와 1클럭 동기 읽기를 제공하는 데이터 RAM이다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_data_ram #(
  parameter int BYTES = 2048,
  parameter int RAM_AW = $clog2(BYTES)
) (
  input  logic clk, rst_n,
  input  logic wr_en_i,
  input  logic [RAM_AW-1:0] wr_addr_i,
  input  logic [7:0] wr_data_i,
  input  logic rd_en_i,
  input  logic [RAM_AW-1:0] rd_addr_i,
  output logic rd_valid_o,
  output logic [7:0] rd_data_o
);
  logic [7:0] mem [0:BYTES-1];
  always_ff @(posedge clk) begin
    if (rst_n && wr_en_i) mem[wr_addr_i] <= wr_data_i;
    if (rst_n && rd_en_i) rd_data_o <= mem[rd_addr_i];
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_valid_o <= 1'b0;
    else rd_valid_o <= rd_en_i;
  end
`ifndef SYNTHESIS
  a_no_read_write: assert property (@(posedge clk) disable iff (!rst_n) !(wr_en_i && rd_en_i)) else $fatal(1, "a_no_read_write");
  a_write_in_range: assert property (@(posedge clk) disable iff (!rst_n) wr_en_i |-> int'(wr_addr_i) < BYTES) else $fatal(1, "a_write_in_range");
  a_read_in_range: assert property (@(posedge clk) disable iff (!rst_n) rd_en_i |-> int'(rd_addr_i) < BYTES) else $fatal(1, "a_read_in_range");
`endif
endmodule
