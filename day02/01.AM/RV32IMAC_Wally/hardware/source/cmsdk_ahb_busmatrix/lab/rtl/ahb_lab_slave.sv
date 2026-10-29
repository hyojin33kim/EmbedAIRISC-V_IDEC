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
    end else begin
      // 여기에 작성: HREADY=1이면 d_valid/d_write/d_offset/d_size/d_error/wait_left 저장,
      //             HREADY=0이고 wait_left≠0이면 wait_left 감소
    end
  end
  // <<< TODO

  // >>> TODO(Lab 1-2): 데이터 단계의 HREADYOUT과 HRESP를 만든다.
  //     대기 중: HREADYOUT=0 / 정상 완료: HREADYOUT=1, HRESP=0
  //     ERROR: 1번째 cycle HREADYOUT=0, HRESP=1 → 2번째 cycle HREADYOUT=1, HRESP=1
  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) err_second <= 1'b0;
    else err_second <= 1'b0;               // 여기에 작성: ERROR 2번째 cycle 표시
  end
  assign HREADYOUT = 1'b1;                 // 여기에 작성
  assign HRESP     = 1'b0;                 // 여기에 작성
  // <<< TODO

  // >>> TODO(Lab 1-3): HSIZE와 주소 하위 2 bit로 쓸 byte lane을 고른다 (little endian).
  always_comb begin
    lanes = 4'b1111;                       // 여기에 작성: HSIZE 0/1/2에 따라 lane 선택
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
