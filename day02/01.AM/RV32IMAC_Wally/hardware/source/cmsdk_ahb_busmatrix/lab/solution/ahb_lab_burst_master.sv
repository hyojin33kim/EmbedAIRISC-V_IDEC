// Lab 3: 주소 단계와 데이터 단계를 겹쳐 SINGLE/INCR4/INCR8/INCR16 word burst를 실행하는 AHB-Lite master이다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module ahb_lab_burst_master #(
  parameter int ADDR_W = 32
) (
  input  logic              HCLK, HRESETn,
  // 명령: burst 0=SINGLE, 3=INCR4, 5=INCR8, 7=INCR16 (HBURST 인코딩 그대로)
  input  logic              cmd_valid,
  output logic              cmd_ready,
  input  logic              cmd_write,
  input  logic [ADDR_W-1:0] cmd_addr,
  input  logic [2:0]        cmd_burst,
  input  logic [31:0]       wbuf [16],     // 쓰기 데이터 (beat 순서)
  output logic [31:0]       rbuf [16],     // 읽은 데이터 (beat 순서)
  output logic              rsp_valid,
  output logic              rsp_error,
  output logic [ADDR_W-1:0] rsp_error_addr,
  output logic [4:0]        rsp_beats,     // OKAY로 끝난 beat 수
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
  logic              active, a_valid, d_valid, write_q;
  logic [2:0]        burst_q;
  logic [4:0]        beats, a_index, d_index, done;
  logic [ADDR_W-1:0] a_addr, d_addr;
  logic [4:0]        cmd_beats;
  logic              crosses_1k;

  always_comb begin
    case (cmd_burst)
      3'b011:  cmd_beats = 5'd4;
      3'b101:  cmd_beats = 5'd8;
      3'b111:  cmd_beats = 5'd16;
      default: cmd_beats = 5'd1;
    endcase
    // burst는 1 KiB 경계를 넘을 수 없다 (마지막 beat 주소의 [ADDR_W-1:10]이 같아야 함)
    crosses_1k = cmd_addr[9:0] + {3'b0, cmd_beats, 2'b00} > 11'd1024;
  end

  assign cmd_ready = !active && !rsp_valid;
  assign HWRITE    = write_q;
  assign HSIZE     = 3'd2;                  // word
  assign HBURST    = burst_q;
  assign HPROT     = 4'b0011;
  assign HMASTLOCK = 1'b0;
  assign HADDR     = a_addr;

  // >>> TODO(Lab 3-1): HTRANS — 첫 beat는 NONSEQ, 이후 beat는 SEQ, 주소 단계가 없으면 IDLE
  assign HTRANS = a_valid ? (a_index == 0 ? 2'b10 : 2'b11) : 2'b00;
  // <<< TODO
  assign HWDATA = d_valid && write_q ? wbuf[d_index[3:0]] : 32'h0;

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      active <= 1'b0; a_valid <= 1'b0; d_valid <= 1'b0; write_q <= 1'b0; burst_q <= '0;
      beats <= '0; a_index <= '0; d_index <= '0; done <= '0; a_addr <= '0; d_addr <= '0;
      rsp_valid <= 1'b0; rsp_error <= 1'b0; rsp_error_addr <= '0; rsp_beats <= '0;
      for (int i = 0; i < 16; i++) rbuf[i] <= '0;
    end else begin
      rsp_valid <= 1'b0;
      if (cmd_valid && cmd_ready) begin
        write_q <= cmd_write; burst_q <= cmd_burst; beats <= cmd_beats;
        a_index <= '0; done <= '0; rsp_error <= 1'b0; rsp_beats <= '0;
        if (crosses_1k) begin                 // 버스에 내보내지 않고 거부
          rsp_valid <= 1'b1; rsp_error <= 1'b1; rsp_error_addr <= cmd_addr;
        end else begin
          active <= 1'b1; a_valid <= 1'b1; a_addr <= cmd_addr;
        end
      end else if (active) begin
        // ERROR 첫 cycle (HREADY=0, HRESP=1): 남은 주소 단계를 IDLE로 취소
        if (d_valid && !HREADY && HRESP) a_valid <= 1'b0;
        if (HREADY) begin
          if (d_valid && HRESP) begin           // ERROR 두 번째 cycle: 종료
            active <= 1'b0; a_valid <= 1'b0; d_valid <= 1'b0;
            rsp_valid <= 1'b1; rsp_error <= 1'b1; rsp_error_addr <= d_addr; rsp_beats <= done;
          end else begin
            // >>> TODO(Lab 3-2): HREADY=1이면 주소 단계 → 데이터 단계로 한 칸 이동,
            //     다음 beat 주소는 +4, 마지막 beat의 주소 단계 뒤에는 a_valid = 0
            d_valid <= a_valid;
            if (a_valid) begin
              d_index <= a_index;
              d_addr  <= a_addr;
              if (a_index + 5'd1 == beats) a_valid <= 1'b0;
              else begin
                a_index <= a_index + 5'd1;
                a_addr  <= a_addr + ADDR_W'(4);
              end
            end
            // <<< TODO
            if (d_valid) begin
              if (!write_q) rbuf[d_index[3:0]] <= HRDATA;
              done <= done + 5'd1;
              if (d_index + 5'd1 == beats) begin  // 마지막 데이터 단계 완료
                active <= 1'b0;
                rsp_valid <= 1'b1; rsp_beats <= done + 5'd1;
              end
            end
          end
        end
      end
    end
  end
endmodule
