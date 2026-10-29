// Lab 7/8: CSR을 직접 설정해 tinynpu_top으로 CNN 계층을 실행하고 C 정답과 CYCLES 구성을 비교한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab7_top_layer;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic s_HSEL, s_HWRITE, s_HMASTLOCK, s_HREADY, s_HRESP;
  logic [33:0] s_HADDR, m_HADDR;
  logic [31:0] s_HWDATA, s_HRDATA, m_HWDATA, m_HRDATA;
  logic [3:0] s_HWSTRB, s_HPROT, m_HWSTRB, m_HPROT;
  logic [2:0] s_HSIZE, s_HBURST, m_HSIZE, m_HBURST;
  logic [1:0] s_HTRANS, m_HTRANS;
  logic m_HWRITE, m_HMASTLOCK, m_HREADY, m_HRESP, irq;

  // 공유 SRAM 배치 (ahb_sram_model: 0x8000_0000부터 64 KiB)
  localparam logic [31:0] INPUT = 32'h80001000, BUF_A = 32'h80004000, BUF_B = 32'h80005000;
  localparam logic [31:0] QPARAM = 32'h80007000, WEIGHT = 32'h80008000;
  int op [6], relu [6], in_c [6], in_h [6], in_w [6], out_c [6], iz [6], oz [6], wbytes [6], obytes [6];
  int load_in, load_wgt, compute, store, control, layer_class;
  byte unsigned image [1024], weights [19240], qparams [1476], expected [2048];
  string vectors = "vectors";

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

  // CSR BUSY 동안 controller 상태별로 cycle을 나눈다 (합계 = CYCLES).
  always @(posedge clk) begin
    if (rst_n && dut.csr.busy) begin
      case (dut.controller.state)
        dut.controller.QP_LOAD_REQ, dut.controller.QP_LOAD_WAIT,
        dut.controller.IFM_LOAD_REQ, dut.controller.IFM_LOAD_WAIT: load_in++;
        dut.controller.WGT_LOAD_REQ, dut.controller.WGT_LOAD_WAIT: load_wgt++;
        dut.controller.COMPUTE_REQ, dut.controller.COMPUTE_WAIT: compute++;
        dut.controller.OFM_STORE_REQ, dut.controller.OFM_STORE_WAIT: store++;
        default: control++;
      endcase
    end
  end

  // >>> TODO(Lab 7): 계층 L을 실행하도록 CSR 8개를 쓴다 (START는 TB가 쓴다).
  //     OP 0x020 = {RELU<<8 | OP}, 주소 0x024 SRC / 0x028 WEIGHT / 0x02C DST / 0x030 QPARAM,
  //     IN_SHAPE 0x034 = {C<<16 | W<<8 | H}, OUT_CHANNELS 0x038, ZERO_POINTS 0x03C = {OZ<<8 | IZ}
  task automatic program_layer(input int L, input logic [31:0] src, dst, wgt, qp);
    // 예: cpu.write_reg(12'h024, src);
    // 계층 정보: op[L], relu[L], in_c[L], in_h[L], in_w[L], out_c[L], iz[L], oz[L]
  endtask
  // <<< TODO

  // >>> TODO(Lab 8): 계층별 COMPUTE cycle(COMPUTE_REQ + COMPUTE_WAIT)을 식으로 예측한다 (모르면 -1).
  //     Conv: OUT_C x (OH x OW x (16 x 9 x IN_C + 20) + 2),  FC: OUT_C x (4 x N + 12)
  int exp_compute [6] = '{-1, -1, -1, -1, -1, -1};
  // <<< TODO

  function automatic string verdict(input bit ok);
    return ok ? "OK" : "다시 확인";
  endfunction

  function automatic string class_name(input int index);
    return index == 0 ? "paper" : index == 1 ? "rock" : "scissors";
  endfunction

  task automatic load_hex(input string name, output byte unsigned data []);
    logic [7:0] buffer [0:19239];
    int count;
    $readmemh({vectors, "/", name}, buffer);
    count = 0;
    while (count < 19240 && buffer[count] !== 8'hxx) count++;
    data = new [count];
    foreach (data[i]) data[i] = buffer[i];
  endtask

  task automatic place(input logic [31:0] address, input byte unsigned data []);
    foreach (data[i]) ram.mem[int'(address - 32'h80000000) + i] = data[i];
  endtask

  task automatic run_layer(input int L, input logic [31:0] src, dst, wgt, qp, output bit ok);
    logic [31:0] status, code, address, cycles;
    byte unsigned golden [];
    int mismatches;
    load_in = 0; load_wgt = 0; compute = 0; store = 0; control = 0;
    program_layer(L, src, dst, wgt, qp);
    cpu.write_reg(12'h008, 32'h1);
    wait (irq === 1'b1);
    cpu.read_reg(12'h00c, status);
    cpu.read_reg(12'h014, code);
    cpu.read_reg(12'h018, address);
    cpu.read_reg(12'h01c, cycles);
    cpu.write_reg(12'h00c, 32'h6);
    load_hex($sformatf("expected_L%0d.hex", L), golden);
    mismatches = 0;
    foreach (golden[i]) if (ram.mem[int'(dst - 32'h80000000) + i] !== golden[i]) mismatches++;
    ok = status == 32'h2 && mismatches == 0;
    if (status != 32'h2)
      $display("[LAB7] L%0d ERROR_CODE=0x%02h ERROR_ADDR=0x%08h — CSR 설정(program_layer)을 확인", L, code, address);
    $display("[LAB7] L%0d %s %2dx%2dx%2d -> %2d ch | CYCLES=%8d (QP+IFM %6d, WGT %6d, COMPUTE %8d, OFM %5d, 제어 %5d) | 출력 %0d B 불일치 %0d",
             L, op[L] ? "FC  " : "CONV", in_c[L], in_h[L], in_w[L], out_c[L], cycles, load_in, load_wgt,
             compute, store, control, golden.size(), mismatches);
  endtask

`ifdef FSDB
  initial begin
    string file = "lab7.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, lab7_top_layer);
  end
`endif

  initial begin
    int fd, first, wsum, qsum, passed, matched;
    logic [31:0] src, dst;
    byte unsigned data [];
    bit ok, all;
    int woffset [6], qoffset [6], compute_measured [6];
    void'($value$plusargs("VECTORS=%s", vectors));
    all = $test$plusargs("ALL");
    fd = $fopen({vectors, "/layers.txt"}, "r");
    if (!fd) $fatal(1, "vectors/layers.txt 없음 — make vectors 실행");
    wsum = 0; qsum = 0;
    for (int L = 0; L < 6; L++) begin
      void'($fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n", op[L], relu[L], in_c[L], in_h[L], in_w[L],
                    out_c[L], iz[L], oz[L], wbytes[L], obytes[L]));
      woffset[L] = wsum; qoffset[L] = qsum;
      wsum += wbytes[L]; qsum += 12 * out_c[L];
    end
    $fclose(fd);
    load_hex("input.hex", data); place(INPUT, data);
    load_hex("weights.hex", data); place(WEIGHT, data);
    load_hex("qparam.hex", data); place(QPARAM, data);

    repeat (3) @(posedge clk);
    @(negedge clk); rst_n = 1;
    repeat (2) @(posedge clk);
    cpu.write_reg(12'h010, 32'h3);
    first = all ? 0 : 5;
    if (!all) begin
      load_hex("expected_L4.hex", data);
      place(BUF_A, data);
    end
    passed = 0; matched = 0;
    for (int L = first; L < 6; L++) begin
      src = L == 0 ? INPUT : (L % 2 == 1 ? BUF_A : BUF_B);
      dst = L % 2 == 0 ? BUF_A : BUF_B;
      run_layer(L, src, dst, WEIGHT + 32'(woffset[L]), QPARAM + 32'(qoffset[L]), ok);
      compute_measured[L] = compute;
      if (ok) passed++;
    end
    begin
      byte unsigned score [3];
      for (int i = 0; i < 3; i++) score[i] = ram.mem[int'(BUF_B - 32'h80000000) + i];
      layer_class = score[1] > score[0] ? (score[2] > score[1] ? 2 : 1) : (score[2] > score[0] ? 2 : 0);
      $display("[LAB7] FC2 score = [%0d, %0d, %0d] -> %s", score[0], score[1], score[2], class_name(layer_class));
    end
    if (all) begin
      for (int L = 0; L < 6; L++) begin
        $display("[LAB8] L%0d COMPUTE RTL=%0d 예상=%0d %s", L, compute_measured[L], exp_compute[L],
                 verdict(compute_measured[L] == exp_compute[L]));
        if (compute_measured[L] == exp_compute[L]) matched++;
      end
      if (passed == 6 && matched == 6) $display("[PASS] lab8 6계층 출력 일치, COMPUTE cycle 6/6 일치");
      else $display("[TODO] lab8 출력 %0d/6, COMPUTE cycle %0d/6 일치", passed, matched);
    end else begin
      if (passed == 1) $display("[PASS] lab7 FC2 출력 3 B가 C 정답과 일치");
      else $display("[TODO] lab7 FC2 출력 불일치 — program_layer의 CSR 값을 확인");
    end
    $finish;
  end
  initial begin #100000000; $fatal(1, "lab7 timeout"); end
endmodule
