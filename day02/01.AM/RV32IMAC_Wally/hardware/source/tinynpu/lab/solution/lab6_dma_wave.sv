// Lab 6: tinynpu_dma의 read/write/ERROR 전송을 AHB SRAM 모델에서 실행하고 burst·byte lane·오류 응답을 예측한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab6_dma_wave;
  import tinynpu_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic cmd_valid = 0, cmd_ready, rsp_valid, rsp_ready = 0;
  npu_dma_cmd_t cmd = '0;
  npu_dma_rsp_t rsp;
  logic lm_req_valid, lm_req_write, lm_rsp_valid = 0, lm_rsp_ready;
  logic [1:0] lm_req_space;
  logic [11:0] lm_req_addr;
  logic [7:0] lm_req_wdata, lm_rsp_rdata = 0;
  logic [33:0] HADDR;
  logic [31:0] HWDATA, HRDATA;
  logic [3:0] HWSTRB, HPROT;
  logic [2:0] HSIZE, HBURST;
  logic [1:0] HTRANS;
  logic HWRITE, HMASTLOCK, HREADY, HRESP;
  logic [5:0] wait_cycles = 0;
  logic error_enable = 0, error_write = 0;
  logic [33:0] error_addr = 0;
  byte unsigned local_ifm [2048], local_ofm [2048];
  string bus_plan, strobes;
  int beats = 0, local_copies = 0, cycles = 0, matched = 0;
  bit running = 0;

  tinynpu_dma dut (
    .clk, .rst_n, .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp),
    .lm_req_valid_o(lm_req_valid), .lm_req_ready_i(!lm_rsp_valid), .lm_req_write_o(lm_req_write),
    .lm_req_space_o(lm_req_space), .lm_req_addr_o(lm_req_addr), .lm_req_wdata_o(lm_req_wdata),
    .lm_rsp_valid_i(lm_rsp_valid), .lm_rsp_ready_o(lm_rsp_ready), .lm_rsp_rdata_i(lm_rsp_rdata),
    .lm_rsp_error_i(1'b0), .m_HADDR(HADDR), .m_HWDATA(HWDATA), .m_HWSTRB(HWSTRB), .m_HWRITE(HWRITE),
    .m_HMASTLOCK(HMASTLOCK), .m_HSIZE(HSIZE), .m_HBURST(HBURST), .m_HPROT(HPROT),
    .m_HTRANS(HTRANS), .m_HRDATA(HRDATA), .m_HREADY(HREADY), .m_HRESP(HRESP));
  ahb_sram_model #(.BYTES(16384)) ram (.clk, .rst_n, .HADDR, .HWRITE, .HSIZE, .HBURST, .HTRANS,
    .HWDATA, .HWSTRB, .HRDATA, .HREADY, .HRESP, .wait_cycles, .random_wait(1'b0),
    .error_enable, .error_write, .error_addr);

  // 내부 RAM 모델: 요청 다음 cycle에 응답 (tinynpu_local_mem과 같은 1-cycle)
  always @(posedge clk) begin
    if (lm_rsp_valid && lm_rsp_ready) lm_rsp_valid <= 0;
    if (lm_req_valid && !lm_rsp_valid) begin
      lm_rsp_valid <= 1;
      local_copies++;
      if (lm_req_write) local_ifm[lm_req_addr] = lm_req_wdata;
      else lm_rsp_rdata <= local_ofm[lm_req_addr];
    end
    if (HTRANS[1] && HREADY) begin
      beats++;
      if (HTRANS == 2'b10)
        bus_plan = {bus_plan, bus_plan == "" ? "" : " ", HSIZE == 0 ? "B" : HSIZE == 1 ? "H" :
                    HBURST == 0 ? "W" : $sformatf("W%0d", 2 << HBURST[2:1])};
    end
    if (ram.d_valid && HREADY && HWRITE && !HRESP)
      strobes = {strobes, strobes == "" ? "" : " ", $sformatf("%04b", HWSTRB)};
    if (running) cycles++;
  end

  // >>> TODO(Lab 6): 세 전송의 결과를 예측한다.
  //     A: IFM read 20 B @0x8000_1002 (SRAM wait 1)   B: OFM write 6 B @0x8000_2001
  //     C: IFM read 32 B @0x8000_1000, 0x8000_1008 beat에서 HRESP=ERROR
  string exp_a_plan = "H W4 H";
  int exp_a_beats = 6, exp_a_copies = 20;
  string exp_b_plan = "B H H B";
  string exp_b_strobes = "0010 1100 0011 0100";
  logic [33:0] exp_c_error_addr = 34'h080001008;
  int exp_c_bytes_done = 0;
  int exp_c_internal = 0;
  // <<< TODO

  function automatic string verdict(input bit ok);
    return ok ? "OK" : "다시 확인";
  endfunction

  task automatic check(input string name, input bit ok, input string detail);
    if (ok) matched++;
    $display("[LAB6] %-28s %s %s", name, detail, verdict(ok));
  endtask

  task automatic transfer(input bit write, input logic [1:0] space, input logic [33:0] address, input int length);
    bus_plan = ""; strobes = ""; beats = 0; local_copies = 0; cycles = 0;
    @(negedge clk);
    cmd.write = write; cmd.space = space; cmd.sys_addr = address; cmd.byte_len = 16'(length); cmd_valid = 1;
    @(posedge clk); #1 running = 1;
    @(negedge clk); cmd_valid = 0;
    wait (rsp_valid);
    @(posedge clk); #1 running = 0;
    @(negedge clk); rsp_ready = 1;
    @(negedge clk); rsp_ready = 0;
    $display("[LAB6] %s %0d B @0x%09h: AHB %s, beat %0d, 내부 byte 복사 %0d, cycle %0d, rsp error=%0b internal=%0b addr=0x%09h done=%0d",
             write ? "write" : "read ", length, address, bus_plan, beats, local_copies, cycles,
             rsp.error, rsp.internal_error, rsp.error_addr, rsp.bytes_done);
  endtask

`ifdef FSDB
  initial begin
    string file = "lab6.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, lab6_dma_wave);
  end
`endif

  initial begin
    bit data_ok;
    for (int i = 0; i < 16384; i++) ram.mem[i] = 8'(i);
    for (int i = 0; i < 2048; i++) local_ofm[i] = 8'(8'ha0 + i);
    repeat (2) @(posedge clk);
    @(negedge clk); rst_n = 1;

    wait_cycles = 1;
    transfer(0, SPACE_IFM, 34'h080001002, 20);
    data_ok = 1;
    for (int i = 0; i < 20; i++) data_ok &= local_ifm[i] == 8'('h1002 + i);
    check("A burst 순서", bus_plan == exp_a_plan, $sformatf("RTL=%s 예상=%s", bus_plan, exp_a_plan));
    check("A AHB beat / byte 복사", beats == exp_a_beats && local_copies == exp_a_copies && data_ok,
          $sformatf("RTL=%0d/%0d 예상=%0d/%0d", beats, local_copies, exp_a_beats, exp_a_copies));

    wait_cycles = 0;
    transfer(1, SPACE_OFM, 34'h080002001, 6);
    data_ok = 1;
    for (int i = 0; i < 6; i++) data_ok &= ram.mem['h2001 + i] == local_ofm[i];
    check("B burst 순서", bus_plan == exp_b_plan && data_ok, $sformatf("RTL=%s 예상=%s", bus_plan, exp_b_plan));
    check("B HWSTRB 순서", strobes == exp_b_strobes, $sformatf("RTL=%s 예상=%s", strobes, exp_b_strobes));

    error_enable = 1; error_write = 0; error_addr = 34'h080001008;
    transfer(0, SPACE_IFM, 34'h080001000, 32);
    error_enable = 0;
    check("C error_addr", rsp.error && rsp.error_addr == exp_c_error_addr,
          $sformatf("RTL=0x%09h 예상=0x%09h", rsp.error_addr, exp_c_error_addr));
    check("C bytes_done / internal", rsp.bytes_done == exp_c_bytes_done && rsp.internal_error == exp_c_internal,
          $sformatf("RTL=%0d/%0d 예상=%0d/%0d", rsp.bytes_done, rsp.internal_error, exp_c_bytes_done, exp_c_internal));
    if (matched == 6) $display("[PASS] lab6 DMA 6/6 일치");
    else $display("[TODO] lab6 DMA %0d/6 일치 — 파형에서 HTRANS/HBURST/HSIZE/HWSTRB와 state_q를 확인", matched);
    $finish;
  end
  initial begin #1000000; $fatal(1, "lab6 timeout"); end
endmodule
