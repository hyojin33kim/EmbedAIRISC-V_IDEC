// Lab 2: 명령 하나를 SINGLE 전송 하나로 실행하는 AHB-Lite master이다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module ahb_lab_master #(
  parameter int ADDR_W = 32
) (
  input  logic              HCLK, HRESETn,
  // 명령 / 응답 (valid/ready)
  input  logic              cmd_valid,
  output logic              cmd_ready,
  input  logic              cmd_write,
  input  logic [ADDR_W-1:0] cmd_addr,
  input  logic [2:0]        cmd_size,
  input  logic [31:0]       cmd_wdata,
  output logic              rsp_valid,
  output logic [31:0]       rsp_rdata,
  output logic              rsp_error,
  // AHB-Lite master
  output logic [ADDR_W-1:0] HADDR,
  output logic [1:0]        HTRANS,
  output logic              HWRITE,
  output logic [2:0]        HSIZE,
  output logic [2:0]        HBURST,
  output logic [3:0]        HPROT,
  output logic              HMASTLOCK,
  output logic [31:0]       HWDATA,
  input  logic [31:0]       HRDATA,
  input  logic              HREADY,
  input  logic              HRESP
);
  typedef enum logic [1:0] {IDLE, ADDR, DATA, RESP} state_t;
  state_t state;
  logic              write_q;
  logic [ADDR_W-1:0] addr_q;
  logic [2:0]        size_q;
  logic [31:0]       wdata_q;

  assign cmd_ready = state == IDLE;
  assign rsp_valid = state == RESP;
  assign HBURST    = 3'b000;               // SINGLE
  assign HPROT     = 4'b0011;              // data, privileged
  assign HMASTLOCK = 1'b0;

  // >>> TODO(Lab 2-1): 주소 단계 출력 — ADDR 상태에서만 NONSEQ, 그 외는 IDLE
  assign HTRANS = state == ADDR ? 2'b10 : 2'b00;
  assign HADDR  = addr_q;
  assign HWRITE = write_q;
  assign HSIZE  = size_q;
  // <<< TODO

  // >>> TODO(Lab 2-2): 데이터 단계 출력 — 쓰기 데이터는 DATA 상태에서만
  assign HWDATA = state == DATA && write_q ? wdata_q : 32'h0;
  // <<< TODO

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      state <= IDLE; write_q <= 1'b0; addr_q <= '0; size_q <= 3'd2; wdata_q <= '0;
      rsp_rdata <= '0; rsp_error <= 1'b0;
    end else begin
      case (state)
        IDLE: if (cmd_valid) begin
          write_q <= cmd_write; addr_q <= cmd_addr; size_q <= cmd_size; wdata_q <= cmd_wdata;
          state <= ADDR;
        end
        // >>> TODO(Lab 2-3): 상태 전이 — HREADY=1인 edge에서만 다음 단계로
        //     ADDR → DATA (주소 단계 수락), DATA → RESP (데이터 단계 완료, HRDATA·HRESP 저장)
        ADDR: if (HREADY) state <= DATA;
        DATA: if (HREADY) begin
          rsp_rdata <= HRDATA;
          rsp_error <= HRESP;
          state <= RESP;
        end
        // <<< TODO
        RESP: state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
