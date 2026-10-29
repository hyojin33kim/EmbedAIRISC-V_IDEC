// 보정한 9비트 피연산자의 곱을 32비트 누산기에 더한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_mac (
  input  logic clk, rst_n,
  input  logic clear_i, tap_valid_i,
  input  logic signed [8:0] a_i, b_i,
  output logic signed [31:0] acc_o,
  output logic tap_done_o
);
  logic signed [17:0] product;
  assign product = a_i * b_i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_o <= '0;
      tap_done_o <= 1'b0;
    end else begin
      tap_done_o <= tap_valid_i && !clear_i;
      if (clear_i) acc_o <= '0;
      else if (tap_valid_i) acc_o <= acc_o + {{14{product[17]}}, product};
    end
  end
`ifndef SYNTHESIS
  a_no_clear_tap: assert property (@(posedge clk) disable iff (!rst_n) !(clear_i && tap_valid_i)) else $fatal(1, "a_no_clear_tap");
`endif
endmodule
