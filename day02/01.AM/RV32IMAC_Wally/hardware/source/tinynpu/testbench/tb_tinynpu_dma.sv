// DMA 계획과 바이트 복사의 정렬, 경계, 백프레셔와 오류 처리를 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_dma;
  import tinynpu_pkg::*;
  localparam int AW = NPU_ADDR_W;
  localparam logic [AW-1:0] BASE = 34'h80000000;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic cmd_valid, cmd_ready, rsp_valid, rsp_ready;
  npu_dma_cmd_t cmd;
  npu_dma_rsp_t rsp;
  logic lm_req_valid, lm_req_ready, lm_req_write;
  logic [1:0] lm_req_space;
  logic [11:0] lm_req_addr;
  logic [7:0] lm_req_wdata, lm_rsp_rdata;
  logic lm_rsp_valid, lm_rsp_ready, lm_rsp_error;
  byte unsigned local_mem [0:2047];
  logic lm_busy;
  int lm_delay, cycles, local_requests;
  int local_error_offset = -1;
  logic [AW-1:0] HADDR;
  logic [31:0] HWDATA, HRDATA;
  logic [3:0] HWSTRB, HPROT;
  logic HWRITE, HMASTLOCK, HREADY, HRESP;
  logic [2:0] HSIZE, HBURST;
  logic [1:0] HTRANS;
  logic [5:0] wait_cycles;
  logic random_wait, error_enable, error_write;
  logic [AW-1:0] error_addr;
  logic [AW-1:0] plan_addr;
  logic [15:0] plan_remaining;
  logic plan_valid;
  logic [2:0] plan_size, plan_burst;
  logic [4:0] plan_beats;
  logic [6:0] plan_bytes;
  int cases_run = 0, planner_checks = 0;
  int burst_seen [0:7];

  tinynpu_dma dut (
    .clk, .rst_n, .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_o(rsp),
    .lm_req_valid_o(lm_req_valid), .lm_req_ready_i(lm_req_ready), .lm_req_write_o(lm_req_write),
    .lm_req_space_o(lm_req_space), .lm_req_addr_o(lm_req_addr), .lm_req_wdata_o(lm_req_wdata),
    .lm_rsp_valid_i(lm_rsp_valid), .lm_rsp_ready_o(lm_rsp_ready), .lm_rsp_rdata_i(lm_rsp_rdata), .lm_rsp_error_i(lm_rsp_error),
    .m_HADDR(HADDR), .m_HWDATA(HWDATA), .m_HWSTRB(HWSTRB), .m_HWRITE(HWRITE),
    .m_HMASTLOCK(HMASTLOCK), .m_HSIZE(HSIZE), .m_HBURST(HBURST), .m_HPROT(HPROT),
    .m_HTRANS(HTRANS), .m_HRDATA(HRDATA), .m_HREADY(HREADY), .m_HRESP(HRESP)
  );
  ahb_sram_model #(.ADDR_W(AW), .BASE_ADDR(BASE), .BYTES(16384)) sram (
    .clk, .rst_n, .HADDR, .HWRITE, .HSIZE, .HBURST, .HTRANS, .HWDATA, .HWSTRB,
    .HRDATA, .HREADY, .HRESP, .wait_cycles, .random_wait, .error_enable, .error_write, .error_addr
  );
  tinynpu_dma_plan planner (
    .addr_i(plan_addr), .remaining_i(plan_remaining), .valid_o(plan_valid),
    .size_o(plan_size), .burst_o(plan_burst), .beats_o(plan_beats), .chunk_bytes_o(plan_bytes)
  );

  assign lm_req_ready = rst_n && !lm_busy && !lm_rsp_valid && cycles[1:0] != 0;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lm_busy <= 0;
      lm_delay <= 0;
      cycles <= 0;
      local_requests <= 0;
      lm_rsp_valid <= 0;
      lm_rsp_error <= 0;
      lm_rsp_rdata <= 0;
    end else begin
      cycles <= cycles + 1;
      if (lm_rsp_valid && lm_rsp_ready) lm_rsp_valid <= 0;
      if (lm_busy) begin
        if (lm_delay == 0) begin
          lm_busy <= 0;
          lm_rsp_valid <= 1;
        end else lm_delay <= lm_delay - 1;
      end
      if (lm_req_valid && lm_req_ready) begin
        if (lm_req_addr >= 2048 || lm_req_space !== cmd.space || lm_req_write === cmd.write)
          $fatal(1, "DMA local request metadata mismatch");
        lm_busy <= 1;
        lm_delay <= int'(cycles[2:1]);
        lm_rsp_error <= int'(lm_req_addr) == local_error_offset;
        lm_rsp_rdata <= lm_req_write ? 8'b0 : local_mem[lm_req_addr];
        if (lm_req_write && int'(lm_req_addr) != local_error_offset)
          local_mem[lm_req_addr] <= lm_req_wdata;
        local_requests <= local_requests + 1;
      end
      if (HREADY && HTRANS[1]) burst_seen[HBURST] <= burst_seen[HBURST] + 1;
    end
  end

  function automatic byte unsigned pattern(input int index);
    return 8'((index * 71 + 193) ^ (index >> 2));
  endfunction

  task automatic initialize_payload(input int addr, input int length, input bit write);
    for (int i = 0; i < 2048; i++) local_mem[i] = write ? pattern(i) : 8'ha5;
    for (int i = addr-64; i < addr+length+64; i++)
      sram.mem[i] = write ? 8'h3c : pattern(i-addr);
  endtask

  task automatic run_dma(input npu_dma_cmd_t value, input bit expected_error = 0,
                         input bit internal_error = 0, input int expected_done = -1,
                         input logic [AW-1:0] expected_error_addr = 0);
    int timeout_count;
    npu_dma_rsp_t saved;
    @(negedge clk);
    cmd = value;
    cmd_valid = 1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 0;
    timeout_count = 0;
    while (!rsp_valid) begin
      @(negedge clk);
      timeout_count++;
      if (timeout_count > 100000) $fatal(1, "DMA timeout state=%0d", dut.state_q);
    end
    if (rsp.error !== expected_error || rsp.internal_error !== internal_error ||
        rsp.bytes_done !== 16'(expected_done < 0 ? value.byte_len : expected_done))
      $fatal(1, "DMA response mismatch addr=%h len=%0d write=%0d got=%h expected_done=%0d",
             value.sys_addr, value.byte_len, value.write, rsp, expected_done);
    if (expected_error && rsp.error_addr !== expected_error_addr)
      $fatal(1, "DMA error address got=%h expected=%h", rsp.error_addr, expected_error_addr);
    saved = rsp;
    repeat (4) begin
      @(negedge clk);
      if (!rsp_valid || rsp !== saved || cmd_ready || HTRANS !== 0 || lm_req_valid)
        $fatal(1, "DMA response not held or transaction continued");
    end
    rsp_ready = 1;
    @(negedge clk);
    rsp_ready = 0;
    cases_run++;
  endtask

  task automatic check_payload(input int addr, input int length, input bit write,
                               input int completed_bytes);
    for (int i = 0; i < 2048; i++) begin
      if (local_mem[i] !== (write || i < completed_bytes ? pattern(i) : 8'ha5))
        $fatal(1, "DMA local data mismatch index=%0d actual=%h write=%0d done=%0d",
               i, local_mem[i], write, completed_bytes);
    end
    for (int i = addr-64; i < addr+length+64; i++) begin
      if (sram.mem[i] !== (write ? (i >= addr && i < addr+completed_bytes ? pattern(i-addr) : 8'h3c) : pattern(i-addr)))
        $fatal(1, "DMA external data/canary mismatch addr=%h actual=%h write=%0d done=%0d",
               BASE+AW'(i), sram.mem[i], write, completed_bytes);
    end
  endtask

  task automatic reject_command(input npu_dma_cmd_t value);
    int old_external, old_local;
    old_external = sram.accepted_count;
    old_local = local_requests;
    run_dma(value, 1, 1, 0, value.sys_addr);
    if (sram.accepted_count != old_external || local_requests != old_local)
      $fatal(1, "Invalid DMA command accessed a memory");
  endtask

  initial begin : tests
    int lengths [0:14] = '{1,2,3,4,7,9,15,16,63,64,65,128,288,384,2048};
    int expected_size, expected_beats, expected_burst, words, addr;
    npu_dma_cmd_t value;
    cmd_valid = 0;
    cmd = '0;
    rsp_ready = 0;
    wait_cycles = 0;
    random_wait = 1;
    error_enable = 0;
    error_write = 0;
    error_addr = 0;
    plan_addr = BASE;
    plan_remaining = 0;
    for (int b = 0; b < 8; b++) burst_seen[b] = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    // Independent priority oracle exhaustively spans a complete 1KiB region.
    for (int offset = 0; offset < 1024; offset++) begin
      for (int length = 0; length <= 2048; length++) begin
        plan_addr = BASE + AW'(offset);
        plan_remaining = 16'(length);
        expected_size = 0;
        expected_beats = length == 0 ? 0 : 1;
        expected_burst = 0;
        if (length > 0 && !(offset & 1)) begin
          if ((offset & 3) != 0 || length < 4) expected_size = length >= 2 ? 1 : 0;
          else begin
            expected_size = 2;
            words = length / 4;
            if (words > (1024-offset)/4) words = (1024-offset)/4;
            if (words >= 16) begin expected_beats = 16; expected_burst = 7; end
            else if (words >= 8) begin expected_beats = 8; expected_burst = 5; end
            else if (words >= 4) begin expected_beats = 4; expected_burst = 3; end
          end
        end
        #1;
        if (plan_valid !== (length != 0) || plan_size !== 3'(expected_size) ||
            plan_beats !== 5'(expected_beats) || plan_burst !== 3'(expected_burst) ||
            plan_bytes !== 7'(expected_beats * (1 << expected_size)))
          $fatal(1, "Planner mismatch offset=%0d len=%0d", offset, length);
        planner_checks++;
      end
    end
    for (int boundary = 0; boundary < 2; boundary++) begin
      for (int alignment = 0; alignment < 4; alignment++) begin
        for (int length_index = 0; length_index < 15; length_index++) begin
          for (int direction = 0; direction < 2; direction++) begin
            addr = (boundary == 0 ? 'h2100 : 'h23fc) + alignment;
            value = '{write:1'(direction), sys_addr:BASE+AW'(addr), byte_len:16'(lengths[length_index]),
                      space:direction ? SPACE_OFM : SPACE_IFM};
            initialize_payload(addr, lengths[length_index], 1'(direction));
            run_dma(value);
            check_payload(addr, lengths[length_index], 1'(direction), lengths[length_index]);
          end
        end
      end
    end
    for (int space = 1; space <= 3; space += 2) begin
      addr = 'h2101;
      value = '{write:0, sys_addr:BASE+AW'(addr), byte_len:space == 1 ? 16'd512 : 16'd384, space:2'(space)};
      initialize_payload(addr, value.byte_len, 0);
      run_dma(value);
      check_payload(addr, value.byte_len, 0, value.byte_len);
    end
    // The failing read chunk must not reach local RAM; writes retain OKAY bytes.
    for (int direction = 0; direction < 2; direction++) begin
      for (int failed_chunk = 0; failed_chunk < 2; failed_chunk++) begin
        for (int fail_selector = 0; fail_selector < 3; fail_selector++) begin
          int failed_beat, done_bytes;
          failed_beat = fail_selector == 0 ? 0 : (fail_selector == 1 ? 8 : 15);
          addr = 'h2400;
          value = '{write:1'(direction), sys_addr:BASE+AW'(addr), byte_len:16'd128,
                    space:direction ? SPACE_OFM : SPACE_IFM};
          initialize_payload(addr, 128, 1'(direction));
          error_enable = 1;
          error_write = 1'(direction);
          error_addr = value.sys_addr + AW'(failed_chunk*64 + failed_beat*4);
          done_bytes = failed_chunk*64 + (direction ? failed_beat*4 : 0);
          run_dma(value, 1, 0, done_bytes, error_addr);
          check_payload(addr, 128, 1'(direction), done_bytes);
          error_enable = 0;
        end
      end
      for (int fail_selector = 0; fail_selector < 3; fail_selector++) begin
        int failed_byte, done_bytes;
        failed_byte = fail_selector == 0 ? 0 : (fail_selector == 1 ? 67 : 127);
        addr = 'h2400;
        value = '{write:1'(direction), sys_addr:BASE+AW'(addr), byte_len:16'd128,
                  space:direction ? SPACE_OFM : SPACE_IFM};
        initialize_payload(addr, 128, 1'(direction));
        local_error_offset = failed_byte;
        done_bytes = direction ? (failed_byte/64)*64 : failed_byte;
        run_dma(value, 1, 1, done_bytes, value.sys_addr+AW'(failed_byte));
        check_payload(addr, 128, 1'(direction), done_bytes);
        local_error_offset = -1;
      end
    end
    value = '{write:0, sys_addr:BASE, byte_len:0, space:SPACE_IFM};
    reject_command(value);
    value.byte_len = 2049;
    reject_command(value);
    value.byte_len = 513;
    value.space = SPACE_WGT;
    reject_command(value);
    value.byte_len = 385;
    value.space = SPACE_QPARAM;
    reject_command(value);
    value.byte_len = 4;
    value.write = 1;
    value.space = SPACE_IFM;
    reject_command(value);
    value.write = 0;
    value.space = SPACE_OFM;
    reject_command(value);
    value.space = SPACE_IFM;
    value.sys_addr = BASE-1;
    reject_command(value);
    value.sys_addr = 34'h87ffffff;
    reject_command(value);
    value.sys_addr = 34'h180000000;
    reject_command(value);
    value.sys_addr = 34'h3fffffffe;
    reject_command(value);
    // Reset an active local copy and prove that it does not resume afterward.
    addr = 'h2400;
    initialize_payload(addr, 128, 0);
    @(negedge clk);
    cmd = '{write:0, sys_addr:BASE+AW'(addr), byte_len:16'd128, space:SPACE_IFM};
    cmd_valid = 1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 0;
    wait (lm_req_valid && lm_req_ready);
    @(negedge clk);
    rst_n = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    repeat (10) @(negedge clk);
    if (rsp_valid || HTRANS !== 0 || HWSTRB !== 0 || lm_req_valid || !cmd_ready)
      $fatal(1, "DMA command survived reset");
    initialize_payload(addr, 128, 0);
    run_dma(cmd);
    check_payload(addr, 128, 0, 128);
    if (burst_seen[0] == 0 || burst_seen[3] == 0 || burst_seen[5] == 0 || burst_seen[7] == 0)
      $fatal(1, "Planner did not exercise every required burst format");
    $display("[PASS] tb_tinynpu_dma cases=%0d planner_checks=%0d", cases_run, planner_checks);
    $finish;
  end

  initial begin
    #50000000;
    $fatal(1, "DMA test watchdog expired");
  end
endmodule
