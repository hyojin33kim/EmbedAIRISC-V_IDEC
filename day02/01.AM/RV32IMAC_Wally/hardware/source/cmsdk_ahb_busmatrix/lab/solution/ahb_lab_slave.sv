// Lab 1: 대기 cycle과 2-cycle ERROR를 지원하는 AHB-Lite SRAM slave이다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module ahb_lab_slave #(
  parameter int ADDR_W = 32,
  parameter int MEM_WORDS = 256,           // 1 KiB
  parameter int WAIT_STATES = 0,           // 모든 전송에 넣는 대기 cycle 수
  parameter logic [9:0] RO_BASE = 10'h380  // 이 offset 이상은 쓰기 금지 (ERROR)
) (
  input  logic              HCLK, HRESETn,
  input  logic              HSEL,
  input  logic [ADDR_W-1:0] HADDR,
  input  logic [1:0]        HTRANS,
  input  logic              HWRITE,
  input  logic [2:0]        HSIZE,
  input  logic [31:0]       HWDATA,
  input  logic              HREADY,        // 버스 전체의 HREADY (이전 전송 완료)
  output logic [31:0]       HRDATA,
  output logic              HREADYOUT,
  output logic              HRESP
);
  logic [31:0] mem [MEM_WORDS];
  logic        d_valid, d_write, d_error, err_second;
  logic [9:0]  d_offset;
  logic [2:0]  d_size;
  logic [7:0]  wait_left;
  logic [3:0]  lanes;
  logic        done;

  // >>> TODO(Lab 1-1): 주소 단계 정보를 HREADY가 1인 edge에서만 저장한다.
  //     전송 시작 조건 = HSEL & HTRANS[1] (NONSEQ/SEQ) & HREADY
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      d_valid <= 1'b0; d_write <= 1'b0; d_error <= 1'b0;
      d_offset <= '0; d_size <= '0; wait_left <= '0;
    end else if (HREADY) begin
      d_valid   <= HSEL && HTRANS[1];
      d_write   <= HWRITE;
      d_offset  <= HADDR[9:0];
      d_size    <= HSIZE;
      d_error   <= HSIZE > 3'd2 || (HWRITE && HADDR[9:0] >= RO_BASE);
      wait_left <= 8'(WAIT_STATES);
    end else if (wait_left != 0) begin
      wait_left <= wait_left - 8'd1;
    end
  end
  // <<< TODO

  // >>> TODO(Lab 1-2): 데이터 단계의 HREADYOUT과 HRESP를 만든다.
  //     대기 중: HREADYOUT=0 / 정상 완료: HREADYOUT=1, HRESP=0
  //     ERROR: 1번째 cycle HREADYOUT=0, HRESP=1 → 2번째 cycle HREADYOUT=1, HRESP=1
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) err_second <= 1'b0;
    else err_second <= d_valid && d_error && wait_left == 0 && !err_second;
  end
  assign HREADYOUT = !d_valid || (wait_left == 0 && (!d_error || err_second));
  assign HRESP     = d_valid && d_error && wait_left == 0;
  // <<< TODO

  // >>> TODO(Lab 1-3): HSIZE와 주소 하위 2 bit로 쓸 byte lane을 고른다 (little endian).
  always_comb begin
    case (d_size)
      3'd0:    lanes = 4'b0001 << d_offset[1:0];
      3'd1:    lanes = 4'b0011 << {d_offset[1], 1'b0};
      default: lanes = 4'b1111;
    endcase
  end
  // <<< TODO

  assign done = d_valid && HREADYOUT && !d_error;
  always @(posedge HCLK) begin             // 메모리 배열 (initial 초기화와 함께 쓰므로 always)
    if (done && d_write)
      for (int lane = 0; lane < 4; lane++)
        if (lanes[lane]) mem[d_offset[9:2]][8*lane +: 8] <= HWDATA[8*lane +: 8];
  end
  assign HRDATA = d_valid && !d_write && !d_error ? mem[d_offset[9:2]] : 32'h0;

  initial for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'h0;
endmodule
