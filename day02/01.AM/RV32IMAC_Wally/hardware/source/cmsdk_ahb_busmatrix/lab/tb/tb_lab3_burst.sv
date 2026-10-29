// Lab 3: 학생 burst master로 INCR4/8/16 읽기·쓰기, 1 KiB 경계 거부, burst 중 ERROR 취소를 검사한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_lab3_burst;
  logic HCLK = 0, HRESETn = 0;
  always #5 HCLK = ~HCLK;
  logic        cmd_valid = 0, cmd_ready, cmd_write = 0, rsp_valid, rsp_error;
  logic [31:0] cmd_addr = 0, rsp_error_addr;
  logic [2:0]  cmd_burst = 0;
  logic [31:0] wbuf [16], rbuf [16];
  logic [4:0]  rsp_beats;
  logic [31:0] HADDR, HWDATA, HRDATA, rdata_fast, rdata_slow;
  logic [1:0]  HTRANS;
  logic        HWRITE, HMASTLOCK, HREADY, HRESP, ready_fast, ready_slow, resp_fast, resp_slow, sel_q;
  logic [2:0]  HSIZE, HBURST;
  logic [3:0]  HPROT;
  int          checks = 0, failures = 0;
  string       phase = "";

  ahb_lab_burst_master u_master (.HCLK, .HRESETn, .cmd_valid, .cmd_ready, .cmd_write, .cmd_addr, .cmd_burst,
    .wbuf, .rbuf, .rsp_valid, .rsp_error, .rsp_error_addr, .rsp_beats, .HADDR, .HTRANS, .HWRITE, .HSIZE,
    .HBURST, .HPROT, .HMASTLOCK, .HWDATA, .HRDATA, .HREADY, .HRESP);
  always_ff @(posedge HCLK or negedge HRESETn)
    if (!HRESETn) sel_q <= 1'b0; else if (HREADY) sel_q <= HADDR[12];
  assign HREADY = sel_q ? ready_slow : ready_fast;
  assign HRDATA = sel_q ? rdata_slow : rdata_fast;
  assign HRESP  = sel_q ? resp_slow  : resp_fast;
  ahb_lab_slave #(.WAIT_STATES(0)) u_fast (.HCLK, .HRESETn, .HSEL(HTRANS[1] && !HADDR[12]), .HADDR, .HTRANS,
    .HWRITE, .HSIZE, .HWDATA, .HREADY, .HRDATA(rdata_fast), .HREADYOUT(ready_fast), .HRESP(resp_fast));
  ahb_lab_slave #(.WAIT_STATES(1)) u_slow (.HCLK, .HRESETn, .HSEL(HTRANS[1] && HADDR[12]), .HADDR, .HTRANS,
    .HWRITE, .HSIZE, .HWDATA, .HREADY, .HRDATA(rdata_slow), .HREADYOUT(ready_slow), .HRESP(resp_slow));
  ahb_checker #(.NAME("lab3")) u_check (.HCLK, .HRESETn, .HADDR, .HTRANS, .HWRITE, .HSIZE, .HBURST,
    .HREADY, .HRESP);

  task automatic check(input bit ok, input string message);
    checks++;
    if (!ok) failures++;
    $display("[LAB3] %-46s %s", message, ok ? "OK" : "FAIL");
  endtask

  task automatic burst(input bit write, input logic [31:0] addr, input logic [2:0] kind, output int cycles);
    @(negedge HCLK);
    while (!cmd_ready) @(negedge HCLK);
    cmd_valid = 1; cmd_write = write; cmd_addr = addr; cmd_burst = kind;
    @(posedge HCLK); cycles = 0;
    @(negedge HCLK); cmd_valid = 0;
    while (!rsp_valid) begin @(posedge HCLK); cycles++; @(negedge HCLK); end
  endtask

  function automatic bit same(input int beats, input logic [31:0] seed);
    for (int i = 0; i < beats; i++) if (rbuf[i] !== seed + 32'(i) * 32'h01010101) return 0;
    return 1;
  endfunction

  task automatic fill(input logic [31:0] seed);
    for (int i = 0; i < 16; i++) wbuf[i] = seed + 32'(i) * 32'h01010101;
  endtask

`ifdef FSDB
  initial begin
    string file = "lab3.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, tb_lab3_burst);
  end
`endif

  initial begin
    int cycles, nonseq_before, seq_before;
    repeat (2) @(posedge HCLK);
    @(negedge HCLK); HRESETn = 1;

    phase = "B1 INCR4"; fill(32'h10000000);
    burst(1, 32'h040, 3'b011, cycles);
    burst(0, 32'h040, 3'b011, cycles);
    check(!rsp_error && rsp_beats == 4 && same(4, 32'h10000000), "B1 INCR4 write -> read (fast)");
    check(cycles == 5, $sformatf("B1 INCR4 read = %0d cycles (4 beats + 1)", cycles));

    phase = "B2 INCR8 wait"; fill(32'h20000000);
    burst(1, 32'h1100, 3'b101, cycles);
    burst(0, 32'h1100, 3'b101, cycles);
    check(!rsp_error && rsp_beats == 8 && same(8, 32'h20000000), "B2 INCR8 write -> read (1 wait)");
    check(cycles == 17, $sformatf("B2 INCR8 read with 1 wait = %0d cycles (17)", cycles));

    phase = "B3 INCR16"; fill(32'h30000000);
    burst(1, 32'h200, 3'b111, cycles);
    burst(0, 32'h200, 3'b111, cycles);
    check(!rsp_error && rsp_beats == 16 && same(16, 32'h30000000), "B3 INCR16 write -> read");
    check(cycles == 17, $sformatf("B3 INCR16 read = %0d cycles (17)", cycles));

    phase = "B4 SINGLE";
    burst(0, 32'h204, 3'b000, cycles);
    check(rsp_beats == 1 && rbuf[0] == 32'h31010101, "B4 SINGLE read of beat 1 address");

    phase = "B5 1KiB";
    nonseq_before = u_check.nonseq;
    burst(0, 32'h3F8, 3'b011, cycles);
    check(rsp_error && rsp_error_addr == 32'h3F8 && u_check.nonseq == nonseq_before,
          "B5 INCR4 @0x3F8 crosses 1 KiB -> rejected, no bus");

    phase = "B6 ERROR"; fill(32'h40000000);
    nonseq_before = u_check.nonseq; seq_before = u_check.seq;
    burst(1, 32'h378, 3'b011, cycles);
    check(rsp_error && rsp_error_addr == 32'h380 && rsp_beats == 2,
          $sformatf("B6 INCR4 @0x378: ERROR at 0x%03h after %0d beats", rsp_error_addr, rsp_beats));
    check(u_check.seq - seq_before == 2, "B6 4th beat (0x384) cancelled -> only 2 SEQ");

    check(u_check.errors == 0, $sformatf("protocol checker errors = %0d", u_check.errors));
    if (failures == 0) $display("[PASS] lab3 burst %0d/%0d checks", checks, checks);
    else $display("[FAIL] lab3 burst %0d/%0d checks failed — rtl/ahb_lab_burst_master.sv의 TODO 확인", failures, checks);
    $finish;
  end
  initial begin #200000; $display("[FAIL] lab3 timeout (a_valid / d_valid 진행 확인)"); $finish; end
endmodule
