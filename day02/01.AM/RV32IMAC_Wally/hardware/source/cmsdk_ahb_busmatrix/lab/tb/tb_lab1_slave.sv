// Lab 1: 주소 decoder와 두 slave(대기 0 / 2 cycle)를 BFM으로 구동해 읽기·쓰기·byte lane·ERROR를 검사한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_lab1_slave;
  logic HCLK = 0, HRESETn = 0;
  always #5 HCLK = ~HCLK;
  logic [31:0] HADDR = 0, HWDATA = 0, HRDATA, rdata_fast, rdata_slow;
  logic [1:0]  HTRANS = 0;
  logic        HWRITE = 0, HSEL_fast, HSEL_slow, HREADY, ready_fast, ready_slow, resp_fast, resp_slow, HRESP;
  logic [2:0]  HSIZE = 3'd2;
  logic        sel_q;
  int          checks = 0, failures = 0;
  string       phase = "";

  // decoder: HADDR[12] = 0 → fast (0x0000), 1 → slow (0x1000). 응답 mux는 데이터 단계 기준
  assign HSEL_fast = HTRANS[1] && !HADDR[12];
  assign HSEL_slow = HTRANS[1] &&  HADDR[12];
  always_ff @(posedge HCLK or negedge HRESETn)
    if (!HRESETn) sel_q <= 1'b0; else if (HREADY) sel_q <= HADDR[12];
  assign HREADY = sel_q ? ready_slow : ready_fast;
  assign HRDATA = sel_q ? rdata_slow : rdata_fast;
  assign HRESP  = sel_q ? resp_slow  : resp_fast;

  ahb_lab_slave #(.WAIT_STATES(0)) u_fast (.HCLK, .HRESETn, .HSEL(HSEL_fast), .HADDR, .HTRANS, .HWRITE,
    .HSIZE, .HWDATA, .HREADY, .HRDATA(rdata_fast), .HREADYOUT(ready_fast), .HRESP(resp_fast));
  ahb_lab_slave #(.WAIT_STATES(2)) u_slow (.HCLK, .HRESETn, .HSEL(HSEL_slow), .HADDR, .HTRANS, .HWRITE,
    .HSIZE, .HWDATA, .HREADY, .HRDATA(rdata_slow), .HREADYOUT(ready_slow), .HRESP(resp_slow));
  ahb_checker #(.NAME("lab1")) u_check (.HCLK, .HRESETn, .HADDR, .HTRANS, .HWRITE, .HSIZE,
    .HBURST(3'b000), .HREADY, .HRESP);

  // 전송 목록을 파이프라인으로 실행하는 BFM: 앞 전송의 데이터 단계 동안 다음 주소 단계를 낸다
  bit          t_write [16];
  logic [31:0] t_addr [16], t_wdata [16], t_rdata [16];
  logic [2:0]  t_size [16];
  bit          t_resp [16];
  int          t_stall [16];

  task automatic run_seq(input int n, output int cycles);
    int a = 0, d = -1;
    cycles = 0;
    for (int i = 0; i < n; i++) t_stall[i] = 0;
    @(negedge HCLK);
    while (a < n || d >= 0) begin
      if (a < n) begin HTRANS = 2'b10; HADDR = t_addr[a]; HWRITE = t_write[a]; HSIZE = t_size[a]; end
      else begin HTRANS = 2'b00; HWRITE = 1'b0; end
      HWDATA = d >= 0 && t_write[d] ? t_wdata[d] : 32'h0;
      @(posedge HCLK); cycles++;
      if (HREADY) begin
        if (d >= 0) begin t_rdata[d] = HRDATA; t_resp[d] = HRESP; end
        d = a < n ? a : -1;
        if (a < n) a++;
      end else if (d >= 0) t_stall[d]++;
      @(negedge HCLK);
    end
    HTRANS = 2'b00;
  endtask

  task automatic set(input int i, input bit w, input logic [31:0] addr, input logic [31:0] data = 0,
                     input logic [2:0] size = 3'd2);
    t_write[i] = w; t_addr[i] = addr; t_wdata[i] = data; t_size[i] = size;
  endtask

  task automatic check(input bit ok, input string message);
    checks++;
    if (!ok) failures++;
    $display("[LAB1] %-34s %s", message, ok ? "OK" : "FAIL");
  endtask

`ifdef FSDB
  initial begin
    string file = "lab1.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, tb_lab1_slave);
  end
`endif

  initial begin
    int cycles;
    repeat (2) @(posedge HCLK);
    @(negedge HCLK); HRESETn = 1;

    phase = "T1 word";
    set(0, 1, 32'h000, 32'h11223344); set(1, 0, 32'h000); run_seq(2, cycles);
    check(t_rdata[1] == 32'h11223344 && !t_resp[1], "T1 word write -> read");

    phase = "T2 byte lanes";
    set(0, 1, 32'h005, 32'h0000AA00, 3'd0); set(1, 1, 32'h006, 32'hBBCC0000, 3'd1); set(2, 0, 32'h004);
    run_seq(3, cycles);
    check(t_rdata[2] == 32'hBBCCAA00, $sformatf("T2 byte/half lanes -> 0x%08h", t_rdata[2]));

    phase = "T3 pipeline";
    set(0, 1, 32'h010, 32'hA0A0A0A0); set(1, 1, 32'h014, 32'hB1B1B1B1); set(2, 0, 32'h010); set(3, 0, 32'h014);
    run_seq(4, cycles);
    check(t_rdata[2] == 32'hA0A0A0A0 && t_rdata[3] == 32'hB1B1B1B1, "T3 back-to-back W W R R");
    check(cycles == 5, $sformatf("T3 4 transfers in %0d cycles (5)", cycles));

    phase = "T4 wait states";
    set(0, 1, 32'h1000, 32'hC0FFEE00); set(1, 0, 32'h1000); run_seq(2, cycles);
    check(t_rdata[1] == 32'hC0FFEE00, "T4 slow slave write -> read");
    check(t_stall[0] == 2 && t_stall[1] == 2, $sformatf("T4 HREADY low %0d,%0d cycles (2,2)", t_stall[0], t_stall[1]));
    check(cycles == 7, $sformatf("T4 2 transfers in %0d cycles (7)", cycles));

    phase = "T5 ERROR";
    set(0, 1, 32'h380, 32'hDEADBEEF); set(1, 0, 32'h380); run_seq(2, cycles);
    check(t_resp[0] && t_stall[0] == 1, "T5 write to 0x380 -> 2-cycle ERROR");
    check(!t_resp[1] && t_rdata[1] == 32'h0 && u_fast.mem[8'he0] == 32'h0, "T5 read-only area unchanged");

    phase = "T6 HSIZE";
    set(0, 0, 32'h020, 0, 3'd3); run_seq(1, cycles);
    check(t_resp[0], "T6 HSIZE=doubleword -> ERROR");

    phase = "T7 error+next";
    set(0, 1, 32'h384, 32'h1); set(1, 1, 32'h024, 32'h12345678); set(2, 0, 32'h024); run_seq(3, cycles);
    check(t_resp[0] && !t_resp[1] && t_rdata[2] == 32'h12345678, "T7 ERROR then next transfer OK");

    check(u_check.errors == 0, $sformatf("protocol checker errors = %0d", u_check.errors));
    if (failures == 0) $display("[PASS] lab1 slave %0d/%0d checks", checks, checks);
    else $display("[FAIL] lab1 slave %0d/%0d checks failed — rtl/ahb_lab_slave.sv의 TODO 확인", failures, checks);
    $finish;
  end
  initial begin #100000; $display("[FAIL] lab1 timeout (HREADYOUT이 1로 돌아오는지 확인)"); $finish; end
endmodule
