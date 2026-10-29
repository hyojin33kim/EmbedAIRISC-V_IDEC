// DMA 버스트의 바이트와 워드를 little-endian 순서로 임시 저장한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_dma_stage (
  input logic clk, rst_n,
  input logic byte_wr_en_i,
  input logic [5:0] byte_wr_addr_i,
  input logic [7:0] byte_wr_data_i,
  input logic [5:0] byte_rd_addr_i,
  output logic [7:0] byte_rd_data_o,
  input logic word_wr_en_i,
  input logic [3:0] word_wr_index_i,
  input logic [31:0] word_wr_data_i,
  input logic [3:0] word_rd_index_i,
  output logic [31:0] word_rd_data_o
);
  logic [31:0] words [0:15];

  assign byte_rd_data_o = words[byte_rd_addr_i[5:2]][8*byte_rd_addr_i[1:0] +: 8];
  assign word_rd_data_o = words[word_rd_index_i];

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (byte_wr_en_i)
        words[byte_wr_addr_i[5:2]][8*byte_wr_addr_i[1:0] +: 8] <= byte_wr_data_i;
      if (word_wr_en_i) words[word_wr_index_i] <= word_wr_data_i;
    end
  end

  // synthesis translate_off
  stage_writers_exclusive: assert property (@(posedge clk) disable iff (!rst_n)
    !(byte_wr_en_i && word_wr_en_i))
    else $fatal(1, "DMA staging byte and word writers collided");
  // synthesis translate_on
endmodule
