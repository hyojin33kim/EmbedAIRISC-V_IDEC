// 실제 CPU의 NPU 실행 결과와 반복 추론 사이클을 독립 C 정답에 비교한다.
  logic [7:0] npu_gray[0:1023], npu_golden[0:3746];
  logic [31:0] npu_frame_addr, npu_result_addr, npu_cycles_addr, npu_stats_addr;
  logic npu_previous_done=1'b0;
  int npu_completed=0, npu_dma_addresses=0;
  int npu_sample=124;
  int npu_lengths[6]='{2048,1024,512,128,32,3};
  int npu_offsets[6]='{0,2048,3072,3584,3712,3744};
  logic [31:0] npu_observed_cycles[12];
  string npu_vectors;
  bit npu_cpu_only;
  logic [31:0] npu_selector_addr=32'b0, npu_run_results_addr=32'b0;
  int npu_csr_addresses=0;

  initial begin
    npu_cpu_only=$test$plusargs("CPU_ONLY");
    if ($value$plusargs("COMPARE_MODE_ADDR=%h",npu_selector_addr)) begin end
    if ($value$plusargs("COMPARE_RESULTS_ADDR=%h",npu_run_results_addr)) begin end
    if (npu_cpu_only && (npu_selector_addr==0 || npu_run_results_addr==0))
      $fatal(1,"CPU comparison requires the common compare.elf symbols");
    if (!$value$plusargs("NPU_VECTORS=%s",npu_vectors) ||
        !$value$plusargs("NPU_FRAME_ADDR=%h",npu_frame_addr) ||
        !$value$plusargs("NPU_RESULT_ADDR=%h",npu_result_addr) ||
        !$value$plusargs("NPU_CYCLES_ADDR=%h",npu_cycles_addr) ||
        !$value$plusargs("NPU_STATS_ADDR=%h",npu_stats_addr))
      $fatal(1,"Use make run or make regression to supply NPU golden vectors and ELF symbols");
    if ($value$plusargs("NPU_SAMPLE=%d",npu_sample)) begin end
    $readmemh({npu_vectors,"/gray.hex"},npu_gray);
    $readmemh({npu_vectors,"/trace.hex"},npu_golden);
  end

  function automatic logic [31:0] npu_ram_word(input logic [31:0] address);
    return dut.uncoregen.uncore.ram.ram.memory.ram.RAM[(address-32'h80000000)>>2];
  endfunction
  function automatic logic [7:0] npu_ram_byte(input logic [31:0] address);
    logic [31:0] word_value;
    word_value=npu_ram_word(address);
    return word_value[8*address[1:0]+:8];
  endfunction
  function automatic logic [63:0] npu_ram_u64(input logic [31:0] address);
    return {npu_ram_word(address+32'd4),npu_ram_word(address)};
  endfunction

  // Patch only the read-only input image before boot, after the ELF preload.
  always @(posedge clk) if (LoadMem) begin
    #1;
    for (int i=0;i<1024;i++) begin
      logic [31:0] address;
      address=npu_frame_addr+32'(i);
      dut.uncoregen.uncore.ram.ram.memory.ram.RAM[(address-32'h80000000)>>2][8*address[1:0]+:8]=npu_gray[i];
    end
    if (npu_selector_addr!=0)
      dut.uncoregen.uncore.ram.ram.memory.ram.RAM[(npu_selector_addr-32'h80000000)>>2]=
        npu_cpu_only ? 32'h4e505501 : 32'h4e505500;
  end

  always @(negedge clk) if (!reset) begin
    if (dut.npugen.npu_HTRANS[1] && dut.npugen.npu_HREADY) npu_dma_addresses++;
    if (dut.npugen.csr_HSEL && dut.npugen.csr_HTRANS[1] && dut.npugen.csr_HREADY) npu_csr_addresses++;
    if (dut.npugen.npu.csr.error_flag)
      $fatal(1,"NPU error code=%h address=%h",dut.npugen.npu.csr.last_error.code,dut.npugen.npu.csr.last_error.addr);
    if (dut.npugen.npu.csr.done_flag && !npu_previous_done) begin
      int layer;
      logic [31:0] destination;
      layer=npu_completed%6;
      if (npu_completed>=12) $fatal(1,"Unexpected extra NPU command");
      destination=dut.npugen.npu.csr.shadow_cfg.dst_addr;
      for (int i=0;i<npu_lengths[layer];i++)
        if (npu_ram_byte(destination+32'(i)) !== npu_golden[npu_offsets[layer]+i])
          $fatal(1,"sample=%0d run=%0d layer=%0d byte=%0d got=%h expected=%h",npu_sample,npu_completed/6,layer,i,
                 npu_ram_byte(destination+32'(i)),npu_golden[npu_offsets[layer]+i]);
      npu_observed_cycles[npu_completed]=dut.npugen.npu.csr.cycles;
      $display("[NPU_LAYER] sample=%0d run=%0d layer=%0d bytes=%0d npu_cycles=%0d",npu_sample,npu_completed/6,layer,
               npu_lengths[layer],npu_observed_cycles[npu_completed]);
      npu_completed++;
    end
    npu_previous_done=dut.npugen.npu.csr.done_flag;
    if (Validate) begin
      int predicted;
      logic [63:0] network_cycles, sum_cpu, sum_npu, cpu_cycles;
      logic [31:0] npuc, polls, address;
      if (npu_cpu_only) begin
        if (npu_completed!=0 || npu_dma_addresses!=0 || npu_csr_addresses!=0)
          $fatal(1,"CPU-only accessed NPU: commands=%0d DMA=%0d CSR=%0d",npu_completed,npu_dma_addresses,npu_csr_addresses);
      end else if (npu_completed!=12 || npu_dma_addresses==0)
        $fatal(1,"Real NPU commands missing: %0d",npu_completed);
      if (npu_ram_word(npu_result_addr)!==32'h494e5438 || npu_ram_word(npu_result_addr+32'd28)!==0 ||
          npu_ram_word(npu_result_addr+32'd20)!==32 || npu_ram_word(npu_result_addr+32'd24)!==32)
        $fatal(1,"Invalid firmware_result magic/status/geometry");
      predicted=0;
      for (int i=0;i<3;i++) begin
        if (npu_ram_word(npu_result_addr+32'(8+4*i)) !== {24'b0,npu_golden[3744+i]})
          $fatal(1,"CPU-visible score mismatch at %0d",i);
        if (npu_golden[3744+i]>npu_golden[3744+predicted]) predicted=i;
      end
      if (npu_ram_word(npu_result_addr+32'd4)!==32'(predicted)) $fatal(1,"Argmax mismatch");
      if (npu_run_results_addr!=0)
        for (int run=0;run<2;run++)
          for (int word_index=0;word_index<8;word_index++)
            if (npu_ram_word(npu_run_results_addr+32'(32*run+4*word_index)) !==
                npu_ram_word(npu_result_addr+32'(4*word_index)))
              $fatal(1,"Per-run score/status mismatch run=%0d word=%0d",run,word_index);
      for (int run=0;run<2;run++) begin
        network_cycles=npu_ram_u64(npu_cycles_addr+32'(8*run));
        sum_cpu=0; sum_npu=0;
        if (!npu_cpu_only) for (int layer=0;layer<6;layer++) begin
          address=npu_stats_addr+32'(16*(run*6+layer));
          cpu_cycles=npu_ram_u64(address);
          npuc=npu_ram_word(address+32'd8); polls=npu_ram_word(address+32'd12);
          if (npuc !== npu_observed_cycles[run*6+layer] || npuc==0 || cpu_cycles<64'(npuc) || polls==0)
            $fatal(1,"Invalid CPU/NPU cycle statistics run=%0d layer=%0d",run,layer);
          sum_cpu+=cpu_cycles; sum_npu+=64'(npuc);
          $display("[NPU_METRIC] sample=%0d run=%0d layer=%0d cpu_cycles=%0d npu_cycles=%0d polls=%0d",
                   npu_sample,run,layer,cpu_cycles,npuc,polls);
        end
        if ($isunknown(network_cycles) || network_cycles==0 || network_cycles<sum_cpu || network_cycles<sum_npu)
          $fatal(1,"Network cycle measurement is inconsistent");
        $display("[%s_NETWORK] sample=%0d run=%0d cpu_cycles=%0d npu_cycles=%0d",npu_cpu_only ? "CPU":"NPU",npu_sample,run,network_cycles,sum_npu);
      end
      $display("[PASS] %s firmware sample=%0d commands=%0d trace_bytes=%0d q=%0d,%0d,%0d predicted=%0d DMA=%0d CSR=%0d",
               npu_cpu_only ? "CPU":"NPU",npu_sample,npu_completed,npu_cpu_only ? 0:2*3747,
               npu_golden[3744],npu_golden[3745],npu_golden[3746],predicted,npu_dma_addresses,npu_csr_addresses);
    end
  end

  initial begin
    longint unsigned watchdog_cycles;
    watchdog_cycles=$test$plusargs("CPU_ONLY") ? 64'd1000000000 : 64'd50000000;
    if ($value$plusargs("MAX_CYCLES=%d",watchdog_cycles)) begin end
    repeat(watchdog_cycles) @(posedge clk);
    $fatal(1,"NPU firmware watchdog PC=%h completed=%0d",dut.core.ifu.PCF,npu_completed);
  end
