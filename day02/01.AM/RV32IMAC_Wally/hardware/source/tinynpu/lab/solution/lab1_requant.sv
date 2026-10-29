// Lab 1: 재양자화 결과를 손으로 계산하고 tinynpu_requant의 결과 및 지연과 비교한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab1_requant;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
  logic signed [31:0] acc = 0, multiplier = 1;
  logic [5:0] shift = 1;
  logic [7:0] zero = 0, result;
  logic relu = 0;
  int matched = 0, filled = 0;

  tinynpu_requant dut (.clk, .rst_n, .req_valid_i(req_valid), .req_ready_o(req_ready),
    .acc_i(acc), .multiplier_i(multiplier), .right_shift_i(shift), .output_zero_i(zero),
    .relu_i(relu), .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .result_o(result));

  // 입력: acc, multiplier(M), right_shift(s), OUTPUT_ZERO(Z), ReLU
  localparam int N = 8;
  int case_acc [N] = '{3, 5, 7, -3, -1000, -1000, 25000, 300000};
  int case_m [N] = '{1, 1, 1, 1, 1, 1, 1720615303, 2147483647};
  int case_s [N] = '{1, 1, 1, 1, 1, 1, 40, 31};
  int case_z [N] = '{100, 100, 0, 100, 77, 77, 0, 62};
  bit case_relu [N] = '{0, 0, 0, 0, 1, 0, 1, 0};

  // >>> TODO(Lab 1): 각 case의 UINT8 결과를 손으로 계산해 채운다 (모르면 -1).
  //     result = clamp(round_even(acc*M / 2^s) + Z, ReLU ? Z : 0, 255)
  int expected [N] = '{102, 102, 4, 98, 77, 0, 39, 255};
  // <<< TODO

  task automatic tick;
    @(posedge clk); #1;
  endtask

  task automatic run_case(input int i);
    int latency;
    string verdict;
    @(negedge clk);
    acc = case_acc[i]; multiplier = case_m[i]; shift = 6'(case_s[i]);
    zero = 8'(case_z[i]); relu = case_relu[i]; req_valid = 1;
    tick();
    @(negedge clk); req_valid = 0;
    latency = 0;
    while (!rsp_valid) begin tick(); latency++; end
    if (expected[i] >= 0) filled++;
    if (result == expected[i]) matched++;
    verdict = result == expected[i] ? "OK" : (expected[i] < 0 ? "TODO" : "불일치");
    $display("[LAB1] case %0d acc=%0d M=%0d s=%0d Z=%0d relu=%0b | product=%0d rounded=%0d | RTL=%0d 예상=%0d %s | 수락→응답 %0d cycle",
             i, case_acc[i], case_m[i], case_s[i], case_z[i], case_relu[i], dut.product, dut.rounded32,
             result, expected[i], verdict, latency);
    @(negedge clk); rsp_ready = 1;
    tick();
    @(negedge clk); rsp_ready = 0;
  endtask

`ifdef FSDB
  initial begin
    string file = "lab1.fsdb";
    void'($value$plusargs("FSDB_FILE=%s", file));
    $fsdbDumpfile(file);
    $fsdbDumpvars(0, lab1_requant);
  end
`endif

  initial begin
    repeat (2) tick();
    @(negedge clk); rst_n = 1;
    for (int i = 0; i < N; i++) run_case(i);
    if (matched == N) $display("[PASS] lab1 requant %0d/%0d 일치", matched, N);
    else $display("[TODO] lab1 requant %0d/%0d 일치 (작성 %0d개) — 불일치 case의 반올림·포화·ReLU 단계를 다시 계산", matched, N, filled);
    $finish;
  end
  initial begin #100000; $fatal(1, "lab1 timeout"); end
endmodule
