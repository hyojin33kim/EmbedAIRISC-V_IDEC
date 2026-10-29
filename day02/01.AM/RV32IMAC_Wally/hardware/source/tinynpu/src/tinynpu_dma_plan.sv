// 정렬과 1KiB 경계를 지키는 다음 DMA 버스트를 선택한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_dma_plan #(
  parameter int ADDR_W = tinynpu_pkg::NPU_ADDR_W
) (
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [15:0] remaining_i,
  output logic valid_o,
  output logic [2:0] size_o, burst_o,
  output logic [4:0] beats_o,
  output logic [6:0] chunk_bytes_o
);
  int unsigned words, boundary_words;

  always_comb begin
    valid_o = remaining_i != 0;
    size_o = 3'd0;
    burst_o = 3'b000;
    beats_o = 5'd1;
    chunk_bytes_o = 7'd1;
    words = 0;
    boundary_words = 0;
    if (remaining_i == 0) begin
      beats_o = '0;
      chunk_bytes_o = '0;
    end else if (addr_i[0]) begin
      size_o = 3'd0;
    end else if (addr_i[1] || remaining_i < 4) begin
      if (remaining_i >= 2) begin
        size_o = 3'd1;
        chunk_bytes_o = 7'd2;
      end
    end else begin
      size_o = 3'd2;
      words = int'(remaining_i) / 4;
      boundary_words = (1024 - int'(addr_i[9:0])) / 4;
      if (words > boundary_words) words = boundary_words;
      if (words >= 16) begin
        beats_o = 5'd16;
        burst_o = 3'b111;
      end else if (words >= 8) begin
        beats_o = 5'd8;
        burst_o = 3'b101;
      end else if (words >= 4) begin
        beats_o = 5'd4;
        burst_o = 3'b011;
      end
      chunk_bytes_o = {beats_o, 2'b00};
    end
  end

  // synthesis translate_off
  initial if (ADDR_W != tinynpu_pkg::NPU_ADDR_W)
    $fatal(1, "DMA planner address width must match package");
  // synthesis translate_on
endmodule
