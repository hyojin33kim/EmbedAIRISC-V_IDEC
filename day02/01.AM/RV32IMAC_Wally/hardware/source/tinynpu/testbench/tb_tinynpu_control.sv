// 명령 검사와 AHB 제어 레지스터의 경계 및 오류와 상태 우선순위를 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_control;
  import tinynpu_pkg::*;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, permit = 1;
  logic sel = 0, wr = 0;
  logic [33:0] addr = 0;
  logic [2:0] size = 2;
  logic [1:0] trans = 0;
  logic [31:0] wdata = 0, rdata;
  logic [3:0] strb = 15;
  logic ready, resp, valid, reg_write, commit, reg_error;
  logic [11:0] offset;
  logic [31:0] reg_wdata, reg_rdata;
  logic start_valid, start_ready = 0, busy = 0, done_event = 0, error_event = 0, irq;
  npu_cfg_t active_cfg, cfg;
  npu_error_t event_error = '0, cfg_error;
  npu_shape_t shape;
  logic cfg_ok;
  integer checks = 0, commits = 0;
  logic [31:0] rd, cycles_before;
  integer before_commit;

  tinynpu_ahb_slave slave (
    .clk, .rst_n, .s_HSEL(sel), .s_HWRITE(wr), .s_HREADY(ready && permit),
    .s_HADDR(addr), .s_HSIZE(size), .s_HTRANS(trans), .s_HWDATA(wdata), .s_HWSTRB(strb),
    .s_HRDATA(rdata), .s_HRESP(resp), .s_HREADYOUT(ready),
    .reg_valid_o(valid), .reg_write_o(reg_write), .reg_offset_o(offset),
    .reg_wdata_o(reg_wdata), .reg_commit_o(commit), .reg_rdata_i(reg_rdata), .reg_error_i(reg_error)
  );
  tinynpu_csr csr (
    .clk, .rst_n, .reg_valid_i(valid), .reg_write_i(reg_write), .reg_commit_i(commit),
    .reg_offset_i(offset), .reg_wdata_i(reg_wdata), .reg_rdata_o(reg_rdata), .reg_error_o(reg_error),
    .start_valid_o(start_valid), .start_ready_i(start_ready), .start_cfg_o(active_cfg),
    .busy_i(busy), .done_event_i(done_event), .error_event_i(error_event), .error_i(event_error), .irq_o(irq)
  );
  tinynpu_cfg_check checker_dut (.cfg_i(cfg), .ok_o(cfg_ok), .shape_o(shape), .error_o(cfg_error));
  always @(posedge clk) if (rst_n && commit && reg_write) commits = commits + 1;

  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1, "CONTROL: %s", message);
    checks++;
  endtask
  function automatic npu_cfg_t legal_cfg();
    npu_cfg_t c;
    c = '0;
    c.src_addr = 32'h80001000; c.weight_addr = 32'h80002000;
    c.dst_addr = 32'h80010000; c.qparam_addr = 32'h80008000;
    c.in_c = 1; c.out_c = 1; c.in_h = 2; c.in_w = 2;
    return c;
  endfunction
  task automatic cfg_result(input logic [7:0] code, input logic [31:0] erraddr = 0);
    #1;
    check(cfg_error.code === code && cfg_error.addr === erraddr, "cfg error code/address");
    check(cfg_ok === (code == 0), "cfg ok");
    if (code != 0) check(shape === '0, "invalid cfg clears all shape fields");
  endtask
  task automatic access(input bit write_access, input logic [11:0] off,
                        input logic [31:0] data, input bit expect_error,
                        output logic [31:0] read_data,
                        input logic [2:0] access_size = 2,
                        input logic [3:0] strobe = 15);
    integer old_commits;
    old_commits = commits;
    @(negedge clk);
    sel = 1; trans = 2; wr = write_access; addr = {22'h10080, off}; size = access_size;
    wdata = ~data; strb = 0;
    @(negedge clk);
    sel = 0; trans = 0; wdata = data; strb = strobe;
    #1;
    if (expect_error) begin
      check(resp && !ready && !commit, "first ERROR cycle");
      @(negedge clk); #1;
      check(resp && ready && !commit, "second ERROR cycle");
    end else begin
      check(!resp && ready && commit, "zero wait successful access");
    end
    read_data = rdata;
    @(negedge clk); #1;
    check(!resp && ready, "idle response");
    check(commits == old_commits + ((write_access && !expect_error) ? 1 : 0), "exactly once commit");
  endtask
  task automatic write_reg(input logic [11:0] off, input logic [31:0] data, input bit err = 0);
    logic [31:0] unused_data;
    access(1, off, data, err, unused_data);
  endtask
  task automatic read_reg(input logic [11:0] off, input logic [31:0] expected);
    logic [31:0] value;
    access(0, off, 0, 0, value, 2, 0);
    check(value === expected, $sformatf("register %03x expected %08x got %08x", off, expected, value));
  endtask

  initial begin
    cfg = legal_cfg(); cfg_result(E_NONE);
    check(shape.ifm_bytes == 4 && shape.ofm_bytes == 1 && shape.wgt_per_oc == 9, "minimum Conv shape");
    cfg.in_c = 8; cfg.in_h = 16; cfg.in_w = 16; cfg.out_c = 32; cfg_result(E_NONE);
    check(shape.ifm_bytes == 2048 && shape.ofm_bytes == 2048, "IFM/OFM maximum");
    cfg.in_c = 9; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.in_c = 32; cfg.in_h = 4; cfg.in_w = 4; cfg.out_c = 32; cfg_result(E_NONE);
    check(shape.wgt_per_oc == 288 && shape.wgt_bytes == 9216, "maximum Conv channel weight");
    cfg = legal_cfg(); cfg.in_h = 32; cfg.in_w = 32; cfg.out_c = 9; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.in_h = 3; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.in_w = 3; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.in_c = 0; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.out_c = 33; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.in_h = 255; cfg.in_w = 255; cfg.in_c = 255; cfg_result(E_SHAPE);
    cfg = legal_cfg(); cfg.op = OP_FC; cfg.in_h = 4; cfg.in_w = 32; cfg_result(E_NONE);
    check(shape.ifm_bytes == 128 && shape.wgt_per_oc == 128 && shape.ofm_bytes == 1, "FC128");
    cfg.in_h = 1; cfg.in_w = 129; cfg_result(E_SHAPE);
    cfg.in_h = 5; cfg.in_w = 26; cfg_result(E_SHAPE);
    cfg.in_h = 1; cfg.in_w = 1; cfg_result(E_NONE);
    cfg.op = 3; cfg.in_c = 0; cfg.qparam_addr = 1; cfg_result(E_OP);
    cfg.op = OP_FC; cfg_result(E_SHAPE);
    cfg.in_c = 1; cfg.src_addr = 0; cfg_result(E_ALIGN, 1);
    cfg.qparam_addr = 0; cfg_result(E_RANGE, 0);
    cfg = legal_cfg(); cfg.src_addr = 32'hffffffff; cfg_result(E_RANGE, 32'hffffffff);
    cfg = legal_cfg(); cfg.src_addr = 32'h87fffffc; cfg_result(E_NONE);
    cfg.src_addr = 32'h87fffffd; cfg_result(E_RANGE, 32'h87fffffd);
    cfg = legal_cfg(); cfg.weight_addr = 32'h88000000; cfg.dst_addr = 0;
    cfg_result(E_RANGE, 32'h88000000);
    cfg = legal_cfg(); cfg.dst_addr = 0; cfg.qparam_addr = 0; cfg_result(E_RANGE, 0);
    cfg = legal_cfg(); cfg.qparam_addr = 32'h87fffff8; cfg_result(E_RANGE, 32'h87fffff8);
    cfg = legal_cfg(); cfg.dst_addr = cfg.src_addr + 3; cfg_result(E_OVERLAP, cfg.dst_addr);
    cfg.dst_addr = cfg.src_addr + 4; cfg_result(E_NONE);
    cfg.dst_addr = cfg.weight_addr + 8; cfg_result(E_OVERLAP, cfg.dst_addr);
    cfg.dst_addr = cfg.qparam_addr + 11; cfg_result(E_OVERLAP, cfg.dst_addr);
    cfg = legal_cfg(); cfg.weight_addr = cfg.src_addr; cfg.qparam_addr = cfg.src_addr;
    cfg_result(E_NONE);

    repeat (3) @(negedge clk);
    check(ready && !resp && rdata == 0, "reset slave response");
    rst_n = 1;
    read_reg('h000, 'h544e5055); read_reg('h004, 'h00010000);
    for (int i = 2; i < 16; i++) read_reg(12'(i * 4), 0);
    write_reg('h024, 'h80001234); read_reg('h024, 'h80001234);
    write_reg('h000, 0, 1); write_reg('h004, 0, 1);
    write_reg('h014, 0, 1); write_reg('h018, 0, 1); write_reg('h01c, 0, 1);
    write_reg('h008, 2, 1); write_reg('h00c, 1, 1); write_reg('h010, 4, 1);
    write_reg('h020, 4, 1); write_reg('h034, 'h01000000, 1);
    write_reg('h038, 'h100, 1); write_reg('h03c, 'h10000, 1);
    write_reg('h040, 0, 1);
    access(0, 'hffc, 0, 1, rd);
    access(1, 'h025, 0, 1, rd);
    for (int i = 0; i < 8; i++) if (i != 2) access(1, 'h024, 0, 1, rd, 3'(i));
    for (int i = 0; i < 15; i++) access(1, 'h024, 0, 1, rd, 2, 4'(i));
    read_reg('h024, 'h80001234);

    @(negedge clk); sel = 1; trans = 1; wr = 1; addr = 'h10080000; strb = 15;
    @(negedge clk); sel = 0; trans = 0; #1;
    check(!valid && ready && !resp, "BUSY is not a register request");

    // ERROR 종료 edge의 다음 유효 주소도 누락 없이 수락한다.
    @(negedge clk); sel = 1; trans = 2; wr = 1; addr = 'h10080000;
    @(negedge clk); sel = 0; trans = 0; wdata = 0; #1;
    check(resp && !ready, "pipelined ERROR first cycle");
    @(negedge clk); #1;
    check(resp && ready, "pipelined ERROR terminal cycle");
    sel = 1; trans = 2; addr = 'h10080024;
    @(negedge clk); sel = 0; trans = 0; wdata = 'h80002222; #1;
    check(!resp && ready && commit, "address accepted at ERROR terminal edge");
    @(negedge clk); read_reg('h024, 'h80002222);

    for (int error_phase = 0; error_phase < 2; error_phase++) begin
      @(negedge clk); sel = 1; trans = 2; wr = 1; addr = 'h10080000; strb = 15;
      @(negedge clk); sel = 0; trans = 0;
      if (error_phase != 0) @(negedge clk);
      rst_n = 0;
      @(negedge clk); check(ready && !resp && !valid, "reset clears ERROR phase");
      rst_n = 1;
      read_reg('h000, 'h544e5055);
    end

    // 연속 주소를 받는 동안 이전 데이터 단계의 값만 각 레지스터에 기록한다.
    @(negedge clk); sel = 1; trans = 2; wr = 1; addr = 'h10080024; wdata = 0; strb = 15;
    @(negedge clk); addr = 'h10080028; wdata = 'h80003333;
    @(negedge clk); addr = 'h1008002c; wdata = 'h80004444;
    @(negedge clk); sel = 0; trans = 0; wdata = 'h80005555;
    @(negedge clk);
    read_reg('h024, 'h80003333); read_reg('h028, 'h80004444); read_reg('h02c, 'h80005555);

    // 다른 버스 대기 중 주소 단계가 변경되어도 latch와 commit이 유지된다.
    @(negedge clk); sel = 1; trans = 2; wr = 1; addr = 'h10080024; strb = 15;
    @(negedge clk); permit = 0; addr = 'h10080028; wdata = 'h80006666;
    before_commit = commits;
    repeat (4) begin @(negedge clk); check(commits == before_commit && offset == 'h024, "HREADY stall"); end
    permit = 1; sel = 0; trans = 0;
    @(negedge clk); read_reg('h024, 'h80006666);

    write_reg('h010, 3); write_reg('h020, 'h101); write_reg('h034, 'h010101);
    write_reg('h038, 1); write_reg('h03c, 'hff80); write_reg('h008, 1);
    check(start_valid && active_cfg.src_addr == 'h80006666 && active_cfg.input_zero == 128,
          "START snapshot and pending");
    read_reg('h00c, 1);
    write_reg('h008, 1, 1); write_reg('h020, 0, 1); write_reg('h024, 0, 1);
    write_reg('h008, 0); read_reg('h008, 0);
    @(negedge clk); start_ready = 1; busy = 1;
    @(negedge clk); start_ready = 0;
    check(!start_valid && active_cfg.src_addr == 'h80006666, "snapshot survives acceptance");
    access(0, 'h01c, 0, 0, cycles_before);
    check(cycles_before > 0, "cycles increments while busy");

    // W1C보다 정상 완료 event가 우선하며 완료 edge도 사이클 수에 포함된다.
    @(negedge clk); sel = 1; trans = 2; wr = 1; addr = 'h1008000c; strb = 15;
    @(negedge clk); sel = 0; trans = 0; wdata = 6; done_event = 1;
    @(negedge clk); done_event = 0; busy = 0;
    read_reg('h00c, 2); check(irq, "done level IRQ");
    access(0, 'h01c, 0, 0, rd); check(rd > cycles_before, "completion cycle counted");
    repeat (3) @(negedge clk); read_reg('h01c, rd);
    write_reg('h010, 0); check(!irq, "IRQ masked");
    write_reg('h010, 1); check(irq, "IRQ unmask sticky DONE");
    write_reg('h00c, 2); read_reg('h00c, 0); check(!irq, "DONE W1C");

    write_reg('h010, 2);
    @(negedge clk); sel = 1; trans = 2; wr = 1; addr = 'h1008000c; strb = 15;
    @(negedge clk); sel = 0; trans = 0; wdata = 4; error_event = 1;
    event_error.code = E_DMA_READ; event_error.addr = 'h80001235;
    @(negedge clk); error_event = 0;
    read_reg('h00c, 4); read_reg('h014, E_DMA_READ); read_reg('h018, 'h80001235);
    check(irq, "error level IRQ");
    write_reg('h00c, 4); read_reg('h014, 0); read_reg('h018, 0);
    check(!irq, "ERROR W1C clears IRQ");
    write_reg('h008, 1); check(start_valid, "second START");
    @(negedge clk); rst_n = 0;
    @(negedge clk); check(!start_valid && !irq && ready && !resp, "reset pending state");
    rst_n = 1; read_reg('h00c, 0); read_reg('h024, 0);
    $display("[PASS] tb_tinynpu_control checks=%0d", checks);
    $finish;
  end
  initial begin #1000000; $fatal(1, "CONTROL watchdog"); end
endmodule
