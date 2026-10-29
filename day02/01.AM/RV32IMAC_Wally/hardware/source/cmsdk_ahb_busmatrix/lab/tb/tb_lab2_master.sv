// Lab 2: 학생 AHB master에 명령을 주고 slave 두 개(대기 0 / 2 cycle)와의 읽기·쓰기·ERROR 응답을 검사한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_lab2_master;
  logic HCLK = 0, HRESETn = 0;
  always #5 HCLK = ~HCLK;
  logic        cmd_valid = 0, cmd_ready, cmd_write = 0, rsp_valid, rsp_error;
  logic [31:0] cmd_addr = 0, cmd_wdata = 0, rsp_rdata;
  logic [2:0]  cmd_size = 3'd2;
  logic [31:0] HADDR, HWDATA, HRDATA, rdata_fast, rdata_slow;
  logic [1:0]  HTRANS;
  logic        HWRITE, HMASTLOCK, HREADY, HRESP, ready_fast, ready_slow, resp_fast, resp_slow, sel_q;
  logic [2:0]  HSIZE, HBURST;
  logic [3:0]  HPROT;
  int          checks = 0, failures = 0;

  ahb_lab_master u_master (.HCLK, .HRESETn, .cmd_valid, .cmd_ready, .cmd_write, .cmd_addr, .cmd_size,
    .cmd_wdata, .rsp_valid, .rsp_rdata, .rsp_error, .HADDR, .HTRANS, .HWRITE, .HSIZE, .HBURST, .HPROT,
    .HMASTLOCK, .HWDATA, .HRDATA, .HREADY, .HRESP);
  // decoder와 응답 mux (Lab 1과 같음): 0x0000 fast, 0x1000 slow
  always_ff @(posedge HCLK or negedge HRESETn)
    if (!HRESETn) sel_q <= 1'b0; else if (HREADY) sel_q <= HADDR[12];
  assign HREADY = sel_q ? ready_slow : ready_fast;
  assign HRDATA = sel_q ? rdata_slow : rdata_fast;
  assign HRESP  = sel_q ? resp_slow  : resp_fast;
  ahb_lab_slave #(.WAIT_STATES(0)) u_fast (.HCLK, .HRESETn, .HSEL(HTRANS[1] && !HADDR[12]), .HADDR, .HTRANS,
    .HWRITE, .HSIZE, .HWDATA, .HREADY, .HRDATA(rdata_fast), .HREADYOUT(ready_fast), .HRESP(resp_fast));
  ahb_lab_slave #(.WAIT_STATES(2)) u_slow (.HCLK, .HRESETn, .HSEL(HTRANS[1] && HADDR[12]), .HADDR, .HTRANS,
    .HWRITE, .HSIZE, .HWDATA, .HREADY, .HRDATA(rdata_slow), .HREADYOUT(ready_slow), .HRESP(resp_slow));
  ahb_checker #(.NAME("lab2")) u_check (.HCLK, .HRESETn, .HADDR, .HTRANS, .HWRITE, .HSIZE, .HBURST,
    .HREADY, .HRESP);

  task automatic check(input bit ok, input string message);
    checks++;
    if (!ok) failures++;
    $display("[LAB2] %-44s %s", message, ok ? "OK" : "FAIL");
  endtask

  // 명령 하나: cmd_valid → (cmd_ready) → rsp_valid까지의 cycle을 센다
  task automatic command(input bit write, input logic [31:0] addr, input logic [2:0] size,
                         input logic [31:0] wdata, output logic [31:0] rdata, output bit error,
                         output int cycles);
    @(negedge HCLK);
    while (!cmd_ready) @(negedge HCLK);
    cmd_valid = 1; cmd_write = write; cmd_addr = addr; cmd_size = size; cmd_wdata = wdata;
    @(posedge HCLK); cycles = 0;
    @(negedge HCLK); cmd_valid = 0;
    while (!rsp_valid) begin @(posedge HCLK); cycles++; @(negedge HCLK); end
    rdata = rsp_rdata; error = rsp_error;
  endtask

`ifdef FSDB
  initial begin
    string file = "lab2.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, tb_lab2_master);
  end
`endif

  initial begin
    logic [31:0] rdata;
    bit error;
    int cycles, nonseq_before;
    repeat (2) @(posedge HCLK);
    @(negedge HCLK); HRESETn = 1;

    command(1, 32'h000, 3'd2, 32'h11223344, rdata, error, cycles);
    check(!error, "M1 write word 0x000");
    command(0, 32'h000, 3'd2, 0, rdata, error, cycles);
    check(rdata == 32'h11223344 && !error, $sformatf("M2 read word 0x000 = 0x%08h", rdata));
    check(cycles == 2, $sformatf("M2 zero-wait: ADDR+DATA = %0d cycles (2)", cycles));

    command(1, 32'h001, 3'd0, 32'h0000EE00, rdata, error, cycles);
    command(0, 32'h000, 3'd2, 0, rdata, error, cycles);
    check(rdata == 32'h1122EE44, $sformatf("M3 byte write lane 1 -> 0x%08h", rdata));

    command(1, 32'h1004, 3'd2, 32'hCAFE0001, rdata, error, cycles);
    command(0, 32'h1004, 3'd2, 0, rdata, error, cycles);
    check(rdata == 32'hCAFE0001, "M4 slow slave read back");
    check(cycles == 4, $sformatf("M4 2 wait states: %0d cycles (4)", cycles));

    nonseq_before = u_check.nonseq;
    command(1, 32'h388, 3'd2, 32'h5, rdata, error, cycles);
    check(error, "M5 write to read-only 0x388 -> rsp_error");
    check(cycles == 3, $sformatf("M5 ERROR takes ADDR + 2 cycles = %0d (3)", cycles));
    command(0, 32'h000, 3'd3, 0, rdata, error, cycles);
    check(error, "M6 HSIZE=doubleword -> rsp_error");
    check(u_check.nonseq - nonseq_before == 2 && u_check.seq == 0, "M7 one NONSEQ per command, no SEQ");
    check(u_check.errors == 0, $sformatf("protocol checker errors = %0d", u_check.errors));
    if (failures == 0) $display("[PASS] lab2 master %0d/%0d checks", checks, checks);
    else $display("[FAIL] lab2 master %0d/%0d checks failed — rtl/ahb_lab_master.sv의 TODO 확인", failures, checks);
    $finish;
  end
  initial begin #100000; $display("[FAIL] lab2 timeout (상태 전이와 HREADY 조건 확인)"); $finish; end
endmodule
