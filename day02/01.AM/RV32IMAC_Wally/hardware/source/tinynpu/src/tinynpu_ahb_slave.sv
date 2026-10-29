// AHB 제어 접근의 주소와 데이터 단계를 분리하고 2사이클 오류를 반환한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tinynpu_ahb_slave #(
  parameter int ADDR_W = tinynpu_pkg::NPU_ADDR_W
) (
  input logic clk, rst_n,
  input logic s_HSEL, s_HWRITE, s_HREADY,
  input logic [ADDR_W-1:0] s_HADDR,
  input logic [2:0] s_HSIZE,
  input logic [1:0] s_HTRANS,
  input logic [31:0] s_HWDATA,
  input logic [3:0] s_HWSTRB,
  output logic [31:0] s_HRDATA,
  output logic s_HRESP, s_HREADYOUT,
  output logic reg_valid_o, reg_write_o,
  output logic [11:0] reg_offset_o,
  output logic [31:0] reg_wdata_o,
  output logic reg_commit_o,
  input logic [31:0] reg_rdata_i,
  input logic reg_error_i
);
  logic data_valid, data_write, address_error, error_second;
  logic [11:0] data_offset;
  logic access_error;

  assign access_error = address_error || reg_error_i ||
                        (data_write && s_HWSTRB != 4'b1111);
  assign reg_valid_o = rst_n && data_valid && !error_second;
  assign reg_write_o = data_write;
  assign reg_offset_o = data_offset;
  assign reg_wdata_o = s_HWDATA;
  assign s_HRDATA = rst_n && data_valid && !access_error && !error_second ? reg_rdata_i : 32'b0;
  assign s_HRESP = rst_n && data_valid && (error_second || access_error);
  assign s_HREADYOUT = !rst_n || !data_valid || error_second || !access_error;
  assign reg_commit_o = reg_valid_o && !access_error && s_HREADY;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_valid <= 1'b0;
      data_write <= 1'b0;
      data_offset <= '0;
      address_error <= 1'b0;
      error_second <= 1'b0;
    end else if (data_valid && access_error && !error_second) begin
      error_second <= 1'b1;
    end else if (s_HREADY) begin
      error_second <= 1'b0;
      data_valid <= s_HSEL && s_HTRANS[1];
      data_write <= s_HWRITE;
      data_offset <= s_HADDR[11:0];
      address_error <= s_HSIZE != 3'd2 || s_HADDR[1:0] != 2'b00;
    end
  end
endmodule
