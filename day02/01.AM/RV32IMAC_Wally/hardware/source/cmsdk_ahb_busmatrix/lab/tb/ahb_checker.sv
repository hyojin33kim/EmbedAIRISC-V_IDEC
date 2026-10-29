// AHB-Lite master 쪽 신호를 관찰해 wait 중 신호 유지, burst 주소 증가, 1 KiB 경계 규칙을 검사한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module ahb_checker #(
  parameter int ADDR_W = 32,
  parameter string NAME = "AHB"
) (
  input logic              HCLK, HRESETn,
  input logic [ADDR_W-1:0] HADDR,
  input logic [1:0]        HTRANS,
  input logic              HWRITE,
  input logic [2:0]        HSIZE,
  input logic [2:0]        HBURST,
  input logic              HREADY,
  input logic              HRESP
);
  int errors = 0, nonseq = 0, seq = 0;
  logic              held = 1'b0;
  logic [ADDR_W+8:0] held_bus;
  logic [ADDR_W-1:0] base, expect_addr;
  logic [2:0]        burst_q;
  logic              write_q;

  task automatic fail(input string message);
    errors++;
    $display("[CHECK] %s %0t: %s", NAME, $time, message);
  endtask

  always @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      held <= 1'b0;
    end else begin
      // 정상 wait(HREADY=0, HRESP=0) 동안 주소·제어는 그대로 유지되어야 한다
      if (held && {HADDR, HTRANS, HWRITE, HSIZE, HBURST} !== held_bus)
        fail("address/control changed while HREADY was low");
      held     <= HTRANS[1] && !HREADY && !HRESP;
      held_bus <= {HADDR, HTRANS, HWRITE, HSIZE, HBURST};
      if (HTRANS[1] && HREADY) begin      // 주소 단계가 수락되는 edge
        if (HTRANS == 2'b10) begin
          nonseq++;
          base = HADDR; burst_q = HBURST; write_q = HWRITE;
          expect_addr = HADDR + (ADDR_W'(1) << HSIZE);
        end else begin
          seq++;
          if (HADDR !== expect_addr) fail($sformatf("SEQ address %h expected %h", HADDR, expect_addr));
          if (HADDR[ADDR_W-1:10] !== base[ADDR_W-1:10]) fail("burst crossed a 1 KiB boundary");
          if (HBURST !== burst_q || HWRITE !== write_q) fail("HBURST/HWRITE changed inside a burst");
          expect_addr = HADDR + (ADDR_W'(1) << HSIZE);
        end
      end
    end
  end
endmodule
