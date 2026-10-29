// AHB 마스터의 버스트 주소, 데이터 단계, 대기, 오류와 리셋을 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_ahb_master;
  import tinynpu_pkg::*;
  localparam int AW = NPU_ADDR_W;
  localparam logic [AW-1:0] BASE = 34'h80000000;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic cmd_valid, cmd_ready, rsp_valid, rsp_ready;
  npu_burst_cmd_t cmd;
  npu_burst_rsp_t rsp;
  logic [3:0] stage_ri, stage_wi;
  logic [31:0] stage_rd, stage_wd;
  logic stage_we;
  logic [31:0] stage_words [0:15];
  logic [AW-1:0] HADDR;
  logic [31:0] HWDATA, HRDATA;
  logic [3:0] HWSTRB, HPROT;
  logic HWRITE, HMASTLOCK, HREADY, HRESP;
  logic sram_ready, sram_resp;
  logic idle_error = 0;
  logic [1:0] sram_trans;
  logic [2:0] HSIZE, HBURST;
  logic [1:0] HTRANS;
  logic [5:0] wait_cycles;
  logic random_wait, error_enable, error_write;
  logic [AW-1:0] error_addr;
  int cases_run = 0, accepted = 0, completed = 0;
  bit checking = 0, pending = 0;
  logic [AW-1:0] pending_addr;
  int pending_index;
  npu_burst_cmd_t expected;

  assign stage_rd = stage_words[stage_ri];
  assign HREADY = idle_error ? 1'b0 : sram_ready;
  assign HRESP = idle_error ? 1'b1 : sram_resp;
  assign sram_trans = idle_error ? 2'b00 : HTRANS;
  tinynpu_ahb_master dut (
    .clk, .rst_n, .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp),
    .stage_word_rd_index_o(stage_ri), .stage_word_rd_data_i(stage_rd),
    .stage_word_wr_en_o(stage_we), .stage_word_wr_index_o(stage_wi), .stage_word_wr_data_o(stage_wd),
    .m_HADDR(HADDR), .m_HWDATA(HWDATA), .m_HWSTRB(HWSTRB), .m_HWRITE(HWRITE),
    .m_HMASTLOCK(HMASTLOCK), .m_HSIZE(HSIZE), .m_HBURST(HBURST), .m_HPROT(HPROT),
    .m_HTRANS(HTRANS), .m_HRDATA(HRDATA), .m_HREADY(HREADY), .m_HRESP(HRESP)
  );
  ahb_sram_model #(.ADDR_W(AW), .BASE_ADDR(BASE), .BYTES(4096)) sram (
    .clk, .rst_n, .HADDR, .HWRITE, .HSIZE, .HBURST, .HTRANS(sram_trans), .HWDATA, .HWSTRB,
    .HRDATA, .HREADY(sram_ready), .HRESP(sram_resp), .wait_cycles, .random_wait, .error_enable, .error_write, .error_addr
  );

  function automatic logic [AW-1:0] beat_address(input npu_burst_cmd_t c, input int index);
    longint unsigned span, start_addr, value;
    start_addr = c.addr;
    span = int'(c.beats) * (1 << c.size);
    value = start_addr + index * (1 << c.size);
    if (c.burst != 0 && !c.burst[0])
      value = (start_addr / span) * span + (value % span);
    return AW'(value);
  endfunction

  function automatic logic [3:0] strobes(input logic [AW-1:0] addr, input int size);
    return 4'(((1 << (1 << size)) - 1) << addr[1:0]);
  endfunction

  always @(posedge clk) begin : scoreboard
    logic [3:0] expected_strobe;
    logic [31:0] expected_word;
    int aligned;
    if (!rst_n) pending = 0;
    else if (checking) begin
      if (!pending && (HWSTRB !== 0 || stage_we))
        $fatal(1, "Payload without a valid data phase");
      if (HREADY) begin
        if (pending) begin
          if (!HRESP) begin
            if (expected.write) begin
              expected_strobe = strobes(pending_addr, expected.size);
              expected_word = 0;
              for (int lane = 0; lane < 4; lane++)
                if (expected_strobe[lane]) expected_word[8*lane +: 8] = stage_words[pending_index][8*lane +: 8];
              if (stage_ri !== 4'(pending_index) || HWSTRB !== expected_strobe || HWDATA !== expected_word)
                $fatal(1, "Write data/index/strobe mismatch index=%0d addr=%h", pending_index, pending_addr);
              if (stage_we) $fatal(1, "Write burst asserted stage write");
            end else begin
              aligned = int'(pending_addr - BASE) & ~3;
              for (int lane = 0; lane < 4; lane++) expected_word[8*lane +: 8] = sram.mem[aligned+lane];
              if (!stage_we || stage_wi !== 4'(pending_index) || stage_wd !== expected_word || HWSTRB !== 0)
                $fatal(1, "Read data/index mismatch index=%0d addr=%h", pending_index, pending_addr);
            end
            completed++;
          end else if (stage_we) $fatal(1, "Error beat was stored");
        end
        pending = HTRANS[1];
        if (HTRANS[1]) begin
          if (accepted >= expected.beats || HADDR !== beat_address(expected, accepted) ||
              HTRANS !== (accepted == 0 ? 2'b10 : 2'b11) || HWRITE !== expected.write ||
              HSIZE !== expected.size || HBURST !== expected.burst || HMASTLOCK !== 0)
            $fatal(1, "Address/control mismatch beat=%0d addr=%h expected=%h", accepted, HADDR, beat_address(expected, accepted));
          pending_addr = HADDR;
          pending_index = accepted;
          accepted++;
        end
      end else if (stage_we) $fatal(1, "Stage captured a stalled read");
    end
  end

  task automatic reset_dut;
    @(negedge clk);
    checking = 0;
    rst_n = 0;
    cmd_valid = 0;
    rsp_ready = 0;
    repeat (2) @(negedge clk);
    if (HTRANS !== 0 || HWRITE !== 0 || HWDATA !== 0 || HWSTRB !== 0 || rsp_valid !== 0)
      $fatal(1, "Reset did not quiesce master");
    rst_n = 1;
    repeat (2) @(negedge clk);
    if (HTRANS !== 0 || rsp_valid !== 0 || !cmd_ready) $fatal(1, "Stale transfer after reset");
  endtask

  task automatic start_command(input npu_burst_cmd_t value);
    @(negedge clk);
    expected = value;
    cmd = value;
    accepted = 0;
    completed = 0;
    pending = 0;
    checking = 1;
    cmd_valid = 1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 0;
  endtask

  task automatic run_command(input npu_burst_cmd_t value, input int fail_index = -1,
                             input bit invalid = 0, input bit unrelated_error = 0);
    npu_burst_rsp_t saved;
    int timeout_count, expected_done;
    error_enable = fail_index >= 0;
    error_write = value.write;
    error_addr = beat_address(value, fail_index < 0 ? 0 : fail_index);
    idle_error = unrelated_error;
    start_command(value);
    if (unrelated_error) begin
      repeat (4) begin
        @(negedge clk);
        if (HTRANS !== 2'b10 || HADDR !== value.addr || rsp_valid || stage_we)
          $fatal(1, "Unrelated HRESP canceled the pending first address");
      end
      idle_error = 0;
    end
    timeout_count = 0;
    while (!rsp_valid) begin
      @(negedge clk);
      timeout_count++;
      if (timeout_count > 2000) $fatal(1, "Master timeout");
    end
    expected_done = invalid ? 0 : (fail_index >= 0 ? fail_index : int'(value.beats));
    if (rsp.error !== (invalid || fail_index >= 0) || rsp.cmd_error !== invalid ||
        rsp.beats_done !== 5'(expected_done) || completed != expected_done || pending)
      $fatal(1, "Master response mismatch burst=%0d size=%0d error=%0d got=%h completed=%0d expected=%0d",
             value.burst, value.size, fail_index, rsp, completed, expected_done);
    if ((invalid || fail_index >= 0) && rsp.error_addr !== (invalid ? value.addr : error_addr))
      $fatal(1, "Error address mismatch");
    if (invalid && accepted != 0) $fatal(1, "Invalid command accessed AHB");
    saved = rsp;
    repeat (3) begin
      @(negedge clk);
      if (!rsp_valid || rsp !== saved || cmd_ready || HTRANS !== 0)
        $fatal(1, "Response was not held");
    end
    rsp_ready = 1;
    @(negedge clk);
    rsp_ready = 0;
    checking = 0;
    error_enable = 0;
    cases_run++;
  endtask

  initial begin : tests
    npu_burst_cmd_t value;
    int lengths [0:7] = '{1, 13, 4, 4, 8, 8, 16, 16};
    cmd_valid = 0;
    cmd = '0;
    rsp_ready = 0;
    wait_cycles = 0;
    random_wait = 0;
    error_enable = 0;
    error_write = 0;
    error_addr = 0;
    for (int i = 0; i < 4096; i++) sram.mem[i] = 8'((i * 31) ^ (i >> 3));
    for (int i = 0; i < 16; i++) stage_words[i] = 32'h81c25700 + 32'(i * 16'h0107);
    reset_dut();
    for (int burst = 0; burst < 8; burst++) begin
      for (int size = 0; size < 3; size++) begin
        for (int direction = 0; direction < 2; direction++) begin
          value = '{write:1'(direction), addr:BASE + 34'h134, size:3'(size), burst:3'(burst), beats:5'(lengths[burst])};
          for (int delay_count = 0; delay_count < 9; delay_count++) begin
            wait_cycles = 6'(delay_count == 8 ? 32 : delay_count);
            run_command(value);
          end
          wait_cycles = 3;
          run_command(value, 0);
          if (lengths[burst] > 1) begin
            run_command(value, lengths[burst]/2);
            run_command(value, lengths[burst]-1);
          end
          if (burst != 0 && !(burst & 1)) begin
            for (int offset = 0; offset < lengths[burst]; offset++) begin
              value.addr = BASE + 34'h200 + AW'(offset * (1 << size));
              wait_cycles = 0;
              run_command(value);
            end
          end
        end
      end
    end
    value = '{write:0, addr:BASE + 34'h3fc, size:2, burst:3, beats:4};
    run_command(value, -1, 1);
    value.addr = BASE + 3;
    value.burst = 0;
    value.beats = 1;
    run_command(value, -1, 1);
    value.addr = BASE;
    value.size = 3;
    run_command(value, -1, 1);
    value.size = 2;
    value.beats = 2;
    run_command(value, -1, 1);
    value.burst = 1;
    value.beats = 0;
    run_command(value, -1, 1);
    value.beats = 17;
    run_command(value, -1, 1);
    for (int direction = 0; direction < 2; direction++) begin
      value = '{write:1'(direction), addr:BASE+34'h300, size:2, burst:3, beats:4};
      run_command(value, -1, 0, 1);
    end
    for (int phase = 0; phase < 5; phase++) begin
      value = '{write:1, addr:BASE + 34'h300, size:2, burst:3, beats:4};
      wait_cycles = phase == 1 ? 32 : 0;
      error_enable = phase == 3;
      error_write = 1;
      error_addr = value.addr;
      start_command(value);
      case (phase)
        0: begin end
        1: wait (pending && !HREADY);
        2: wait (completed == 1);
        3: wait (HRESP && !HREADY);
        4: wait (rsp_valid);
      endcase
      reset_dut();
      wait_cycles = 0;
      run_command(value);
    end
    $display("[PASS] tb_tinynpu_ahb_master cases=%0d", cases_run);
    $finish;
  end

  initial begin
    #20000000;
    $fatal(1, "AHB master test watchdog expired");
  end
endmodule
