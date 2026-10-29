// Lab 5: 주소와 길이별로 tinynpu_dma_plan이 고르는 AHB burst 순서를 예측한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lab5_dma_plan;
  import tinynpu_pkg::*;
  logic [NPU_ADDR_W-1:0] addr;
  logic [15:0] remaining;
  logic valid;
  logic [2:0] size, burst;
  logic [4:0] beats;
  logic [6:0] bytes;
  int matched = 0;

  tinynpu_dma_plan dut (.addr_i(addr), .remaining_i(remaining), .valid_o(valid), .size_o(size),
    .burst_o(burst), .beats_o(beats), .chunk_bytes_o(bytes));

  localparam int N = 7;
  string description [N] = '{"Conv2 IFM 로드", "Conv1 QPARAM", "Conv1 WGT oc=1", "1 KiB 경계 앞",
                             "홀수 주소 3 B", "halfword 정렬 20 B", "Conv1 IFM (홀수 시작)"};
  logic [33:0] case_addr [N] = '{34'h080004000, 34'h080007000, 34'h08000800a, 34'h0800003f0,
                                 34'h080004003, 34'h080005002, 34'h080001003};
  int case_len [N] = '{2048, 96, 9, 64, 3, 20, 1024};

  // >>> TODO(Lab 5): burst 순서를 기호로 적는다 (같은 기호가 n번 연속이면 기호*n).
  //     B = BYTE SINGLE, H = HALFWORD SINGLE, W = WORD SINGLE, W4/W8/W16 = INCR4/8/16
  string expected [N] = '{default: "?"};
  // <<< TODO

  function automatic string verdict(input bit ok);
    return ok ? "OK" : "다시 확인";
  endfunction

  initial begin
    for (int i = 0; i < N; i++) begin
      string plan, last, token;
      int repeat_count, bursts, ahb_beats;
      plan = ""; last = ""; repeat_count = 0; bursts = 0; ahb_beats = 0;
      addr = case_addr[i]; remaining = 16'(case_len[i]);
      #1;
      while (valid) begin
        token = size == 0 ? "B" : size == 1 ? "H" : beats == 1 ? "W" : $sformatf("W%0d", beats);
        if (token == last) repeat_count++;
        else begin
          if (last != "") plan = {plan, plan == "" ? "" : " ", last, repeat_count > 1 ? $sformatf("*%0d", repeat_count) : ""};
          last = token; repeat_count = 1;
        end
        bursts++; ahb_beats += beats;
        addr += 34'(bytes); remaining -= 16'(bytes);
        #1;
      end
      plan = {plan, plan == "" ? "" : " ", last, repeat_count > 1 ? $sformatf("*%0d", repeat_count) : ""};
      if (plan == expected[i]) matched++;
      $display("[LAB5] case %0d %-26s 0x%09h + %4d B | RTL: %-24s (burst %0d, beat %0d) | 예상: %-24s %s",
               i, description[i], case_addr[i], case_len[i], plan, bursts, ahb_beats, expected[i],
               verdict(plan == expected[i]));
    end
    if (matched == N) $display("[PASS] lab5 dma_plan %0d/%0d 일치", matched, N);
    else $display("[TODO] lab5 dma_plan %0d/%0d 일치 — 주소 홀수/2 B 정렬/1 KiB 경계 규칙 순서를 확인", matched, N);
    $finish;
  end
endmodule
