// INT64 곱을 짝수 반올림하고 영점 및 포화를 적용한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_requant (
  input  logic clk, rst_n,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic signed [31:0] acc_i, multiplier_i,
  input  logic [5:0] right_shift_i,
  input  logic [7:0] output_zero_i,
  input  logic relu_i,
  output logic rsp_valid_o,
  input  logic rsp_ready_i,
  output logic [7:0] result_o
);
  typedef enum logic [2:0] {R_IDLE, R_PRODUCT, R_ROUND, R_CLAMP, R_RESP} state_t;
  state_t state;
  logic signed [31:0] acc, multiplier, rounded32;
  logic signed [63:0] product, rounded;
  logic [5:0] right_shift;
  logic [7:0] output_zero;
  logic relu;
  logic [63:0] magnitude, quotient, remainder, half, rounded_mag;
  logic increment;
  logic signed [32:0] q, minimum;
  assign req_ready_o = rst_n && state == R_IDLE;
  assign rsp_valid_o = rst_n && state == R_RESP;
  always_comb begin
    magnitude = product[63] ? (~$unsigned(product) + 64'd1) : $unsigned(product);
    quotient = magnitude >> right_shift;
    remainder = magnitude & ((64'd1 << right_shift) - 64'd1);
    half = 64'd1 << (right_shift - 6'd1);
    increment = remainder > half || (remainder == half && quotient[0]);
    rounded_mag = quotient + {63'd0, increment};
    rounded = product[63] ? -$signed(rounded_mag) : $signed(rounded_mag);
    q = $signed({rounded32[31], rounded32}) + $signed({25'd0, output_zero});
    minimum = relu ? $signed({25'd0, output_zero}) : 33'sd0;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= R_IDLE;
      acc <= '0;
      multiplier <= '0;
      right_shift <= 6'd1;
      output_zero <= '0;
      relu <= 1'b0;
      product <= '0;
      rounded32 <= '0;
      result_o <= '0;
    end else begin
      case (state)
        R_IDLE: if (req_valid_i) begin
          acc <= acc_i;
          multiplier <= multiplier_i;
          right_shift <= right_shift_i;
          output_zero <= output_zero_i;
          relu <= relu_i;
          state <= R_PRODUCT;
        end
        R_PRODUCT: begin
          product <= $signed({{32{acc[31]}}, acc}) * $signed({{32{multiplier[31]}}, multiplier});
          state <= R_ROUND;
        end
        R_ROUND: begin
          if (rounded > 64'sd2147483647) rounded32 <= 32'sh7fff_ffff;
          else if (rounded < -64'sd2147483648) rounded32 <= 32'sh8000_0000;
          else rounded32 <= rounded[31:0];
          state <= R_CLAMP;
        end
        R_CLAMP: begin
          if (q < minimum) result_o <= minimum[7:0];
          else if (q > 33'sd255) result_o <= 8'd255;
          else result_o <= q[7:0];
          state <= R_RESP;
        end
        R_RESP: if (rsp_ready_i) state <= R_IDLE;
        default: state <= R_IDLE;
      endcase
    end
  end
`ifndef SYNTHESIS
  a_valid_quantization: assert property (@(posedge clk) disable iff (!rst_n)
    req_valid_i && req_ready_o |-> multiplier_i > 0 && right_shift_i >= 1 && right_shift_i <= 62) else $fatal(1, "a_valid_quantization");
  a_response_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid_o && !rsp_ready_i |=> rsp_valid_o && $stable(result_o)) else $fatal(1, "a_response_stable");
`endif
endmodule
