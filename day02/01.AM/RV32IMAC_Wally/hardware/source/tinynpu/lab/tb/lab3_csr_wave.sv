// Lab 3: CPU 역할의 AHB BFM으로 CSR을 접근하고 응답·ERROR·START 동작을 예측해 파형과 비교한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab3_csr_wave;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic s_HSEL, s_HWRITE, s_HMASTLOCK, s_HREADY, s_HRESP;
  logic [33:0] s_HADDR, m_HADDR;
  logic [31:0] s_HWDATA, s_HRDATA, m_HWDATA, m_HRDATA;
  logic [3:0] s_HWSTRB, s_HPROT, m_HWSTRB, m_HPROT;
  logic [2:0] s_HSIZE, s_HBURST, m_HSIZE, m_HBURST;
  logic [1:0] s_HTRANS, m_HTRANS;
  logic m_HWRITE, m_HMASTLOCK, m_HREADY, m_HRESP, irq;
  int step = -1, resp_cycles = 0, stall_cycles = 0, commits = 0, matched = 0;

  tinynpu_top dut (
    .HCLK(clk), .HRESETn(rst_n),
    .s_HSEL, .s_HADDR, .s_HWDATA, .s_HWSTRB, .s_HWRITE, .s_HSIZE, .s_HBURST,
    .s_HPROT, .s_HTRANS, .s_HMASTLOCK, .s_HREADY, .s_HRDATA, .s_HRESP, .s_HREADYOUT(s_HREADY),
    .m_HADDR, .m_HWDATA, .m_HWSTRB, .m_HWRITE, .m_HSIZE, .m_HBURST,
    .m_HPROT, .m_HTRANS, .m_HMASTLOCK, .m_HRDATA, .m_HREADY, .m_HRESP, .irq_o(irq));
  ahb_master_bfm cpu (.clk, .rst_n, .HSEL(s_HSEL), .HADDR(s_HADDR), .HWDATA(s_HWDATA),
    .HWSTRB(s_HWSTRB), .HWRITE(s_HWRITE), .HSIZE(s_HSIZE), .HBURST(s_HBURST),
    .HPROT(s_HPROT), .HTRANS(s_HTRANS), .HMASTLOCK(s_HMASTLOCK),
    .HRDATA(s_HRDATA), .HREADY(s_HREADY), .HRESP(s_HRESP));
  ahb_sram_model ram (.clk, .rst_n, .HADDR(m_HADDR), .HWRITE(m_HWRITE), .HSIZE(m_HSIZE),
    .HBURST(m_HBURST), .HTRANS(m_HTRANS), .HWDATA(m_HWDATA), .HWSTRB(m_HWSTRB),
    .HRDATA(m_HRDATA), .HREADY(m_HREADY), .HRESP(m_HRESP),
    .wait_cycles(6'd0), .random_wait(1'b0), .error_enable(1'b0), .error_write(1'b0), .error_addr(34'd0));

  always @(posedge clk) begin
    if (s_HRESP) resp_cycles++;
    if (!s_HREADY) stall_cycles++;
    if (dut.reg_commit) commits++;
  end

  // 접근 순서: write 여부, offset, write 데이터 (step 15 전에 irq를 기다린다)
  localparam int N = 18;
  bit acc_write [N] = '{0, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0};
  logic [11:0] acc_offset [N] = '{12'h000, 12'h004, 12'h020, 12'h020, 12'h000, 12'h034, 12'h034, 12'h034,
                                  12'h040, 12'h03c, 12'h03c, 12'h00c, 12'h008, 12'h00c, 12'h024, 12'h00c,
                                  12'h00c, 12'h00c};
  logic [31:0] acc_wdata [N] = '{0, 0, 32'h101, 0, 32'h12345678, 32'h01020304, 0, 32'h00200101,
                                 0, 32'h3e00, 0, 32'h1, 32'h1, 0, 32'h80000000, 0, 32'h2, 0};

  // >>> TODO(Lab 3): 각 접근이 AHB ERROR인지(1/0)와 read 결과를 예측한다 (모르면 -1).
  //     write 접근의 rdata는 비교하지 않으므로 -1 그대로 둔다.
  int exp_error [N] = '{default: -1};
  longint exp_rdata [N] = '{default: -1};
  // <<< TODO

  function automatic string verdict(input bit ok);
    return ok ? "OK" : "다시 확인";
  endfunction

  // FC 32 -> 3 command가 실제로 끝나도록 나머지 CSR과 SRAM의 QPARAM을 준비한다.
  task automatic prepare_command;
    cpu.write_reg(12'h010, 32'h1);
    cpu.write_reg(12'h024, 32'h80001000);
    cpu.write_reg(12'h028, 32'h80002000);
    cpu.write_reg(12'h02c, 32'h80003000);
    cpu.write_reg(12'h030, 32'h80004000);
    cpu.write_reg(12'h038, 32'd3);
    for (int oc = 0; oc < 3; oc++) begin
      ram.mem['h4000 + 12*oc + 4] = 8'd1;
      ram.mem['h4000 + 12*oc + 8] = 8'd1;
    end
  endtask

  task automatic access(input int i);
    logic [31:0] rdata, cycles;
    bit error, ok;
    int commits_before;
    step = i;
    if (i == 12) prepare_command();
    if (i == 15) begin
      wait (irq === 1'b1);
      cpu.read_reg(12'h01c, cycles);
      $display("[LAB3] DONE IRQ 수신, CYCLES = %0d", cycles);
    end
    resp_cycles = 0; stall_cycles = 0; commits_before = commits;
    cpu.access(acc_write[i], 34'h010080000 + 34'(acc_offset[i]), acc_wdata[i], rdata, error);
    ok = error == exp_error[i] && (acc_write[i] || error || rdata == exp_rdata[i]);
    if (ok) matched++;
    $display("[LAB3] step %2d %s 0x%03h %s | ERROR=%0b HRESP %0d cycle, HREADYOUT=0 %0d cycle, commit %0d | rdata=0x%08h | %s",
             i, acc_write[i] ? "W" : "R", acc_offset[i], acc_write[i] ? $sformatf("<= 0x%08h", acc_wdata[i]) : "            ",
             error, resp_cycles, stall_cycles, commits - commits_before, rdata, verdict(ok));
  endtask

`ifdef FSDB
  initial begin
    string file = "lab3.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, lab3_csr_wave);
  end
`endif

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk); rst_n = 1;
    repeat (2) @(posedge clk);
    for (int i = 0; i < N; i++) access(i);
    if (matched == N) $display("[PASS] lab3 CSR %0d/%0d 일치", matched, N);
    else $display("[TODO] lab3 CSR %0d/%0d 일치 — 파형에서 data_valid, access_error, error_second, reg_commit 확인", matched, N);
    $finish;
  end
  initial begin #2000000; $fatal(1, "lab3 timeout"); end
endmodule
