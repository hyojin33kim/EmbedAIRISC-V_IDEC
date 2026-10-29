// 네 개의 부호 있는 누산값에서 최대값을 구한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_pool (
  input  logic clk, rst_n,
  input  logic clear_i, sample_valid_i,
  input  logic signed [31:0] sample_i,
  output logic max_valid_o,
  output logic signed [31:0] max_o
);
  logic [2:0] count;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      count <= '0;
      max_o <= 32'sh8000_0000;
      max_valid_o <= 1'b0;
    end else begin
      max_valid_o <= 1'b0;
      if (clear_i) begin
        count <= '0;
        max_o <= 32'sh8000_0000;
      end else if (sample_valid_i && count < 3'd4) begin
        count <= count + 3'd1;
        if (sample_i > max_o) max_o <= sample_i;
        if (count == 3'd3) max_valid_o <= 1'b1;
      end
    end
  end
`ifndef SYNTHESIS
  a_no_clear_sample: assert property (@(posedge clk) disable iff (!rst_n) !(clear_i && sample_valid_i)) else $fatal(1, "a_no_clear_sample");
  a_four_samples: assert property (@(posedge clk) disable iff (!rst_n) sample_valid_i |-> count < 3'd4) else $fatal(1, "a_four_samples");
`endif
endmodule
