// MAC과 pooling 및 재양자화의 경계값과 무작위 정수 연산을 검증한다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_tinynpu_arithmetic;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic clear = 0, tap = 0, done;
  logic signed [8:0] a = 0, b = 0;
  logic signed [31:0] acc;
  logic pool_clear = 0, sample_valid = 0, max_valid;
  logic signed [31:0] sample = 0, maximum;
  logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
  logic signed [31:0] rq_acc = 0, multiplier = 1;
  logic [5:0] shift = 1;
  logic [7:0] zero = 0, result;
  logic relu = 0;
  int checks = 0;
  tinynpu_mac u_mac (.clk, .rst_n, .clear_i(clear), .tap_valid_i(tap), .a_i(a), .b_i(b), .acc_o(acc), .tap_done_o(done));
  tinynpu_pool u_pool (.clk, .rst_n, .clear_i(pool_clear), .sample_valid_i(sample_valid),
    .sample_i(sample), .max_valid_o(max_valid), .max_o(maximum));
  tinynpu_requant u_rq (.clk, .rst_n, .req_valid_i(req_valid), .req_ready_o(req_ready),
    .acc_i(rq_acc), .multiplier_i(multiplier), .right_shift_i(shift), .output_zero_i(zero), .relu_i(relu),
    .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .result_o(result));
  function automatic byte unsigned reference_q(input int signed x, m, input int unsigned s, z, input bit r);
    longint signed p, rounded, q;
    longint unsigned mag, divisor, whole, remn;
    p = longint'(x) * longint'(m);
    mag = p < 0 ? -p : p;
    divisor = 64'd1 << s;
    whole = mag / divisor;
    remn = mag % divisor;
    if (remn > divisor/2 || (remn == divisor/2 && whole%2 == 1)) whole++;
    rounded = p < 0 ? -longint'(whole) : longint'(whole);
    if (rounded > 2147483647) rounded = 2147483647;
    if (rounded < -64'sd2147483648) rounded = -64'sd2147483648;
    q = rounded + longint'(z);
    if (q < (r ? longint'(z) : 64'sd0)) q = r ? longint'(z) : 64'sd0;
    if (q > 255) q = 255;
    return q[7:0];
  endfunction
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic check_q(input int signed x, m, input int unsigned s, z, input bit r);
    byte unsigned expected;
    expected = reference_q(x, m, s, z, r);
    @(negedge clk);
    if (!req_ready) $fatal(1, "requant not ready");
    rq_acc = x; multiplier = m; shift = 6'(s); zero = 8'(z); relu = r; req_valid = 1;
    tick();
    @(negedge clk); req_valid = 0; rq_acc = 123; multiplier = 7; shift = 3; zero = 0; relu = !r;
    repeat (2) begin tick(); if (rsp_valid) $fatal(1, "requant responded early"); end
    tick();
    if (!rsp_valid || result !== expected) $fatal(1, "requant x=%0d m=%0d s=%0d z=%0d relu=%0b got=%0d expected=%0d", x,m,s,z,r,result,expected);
    repeat (3) begin tick(); if (!rsp_valid || result !== expected || req_ready) $fatal(1, "requant response hold"); end
    @(negedge clk); rsp_ready = 1;
    tick();
    if (rsp_valid || !req_ready) $fatal(1, "requant response retirement");
    @(negedge clk); rsp_ready = 0;
    checks++;
  endtask
  initial begin
    repeat (2) tick(); @(negedge clk); rst_n = 1; clear = 1;
    tick(); @(negedge clk); clear = 0; a = 255; b = 255; tap = 1;
    for (int i=1; i<=288; i++) begin tick(); if (!done || acc !== i*65025) $fatal(1,"positive MAC tap %0d",i); end
    @(negedge clk); tap = 0; clear = 1; tick();
    @(negedge clk); clear = 0; a = -255; b = 255; tap = 1;
    for (int i=1; i<=288; i++) begin tick(); if (!done || acc !== -i*65025) $fatal(1,"negative MAC tap %0d",i); end
    @(negedge clk); tap = 0;
    tick(); if (done || acc !== -18727200) $fatal(1,"MAC idle hold");
    @(negedge clk); pool_clear = 1; tick();
    @(negedge clk); pool_clear = 0; sample_valid = 1;
    for (int i=0; i<4; i++) begin
      sample = -40+i*10; tick();
      if (maximum !== sample || max_valid !== (i == 3)) $fatal(1,"pool fourth sample/signed compare");
      @(negedge clk);
    end
    sample_valid = 0; tick(); if (max_valid || maximum !== -10) $fatal(1,"pool hold");
    check_q(3,1,1,100,0); check_q(5,1,1,100,0);
    check_q(-3,1,1,100,0); check_q(-5,1,1,100,0);
    check_q(32'sh7fffffff,32'sh7fffffff,1,255,0);
    check_q(32'sh80000000,32'sh7fffffff,1,255,0);
    check_q(-1000,1,1,77,1); check_q(-1000,1,1,77,0);
    for (int j=0; j<5; j++) begin
      int s;
      case(j) 0:s=1; 1:s=31; 2:s=39; 3:s=54; default:s=62; endcase
      check_q(18727200,2147483647,s,128,0);
      check_q(-18727200,2147483647,s,128,0);
    end
    for (int i=0; i<500; i++) check_q(int'($urandom),int'($urandom_range(2147483647,1)), $urandom_range(62,1),$urandom_range(255,0),1'($urandom));
    for (int delay_cycles=0; delay_cycles<5; delay_cycles++) begin
      @(negedge clk); req_valid=1; rq_acc=17; multiplier=19; shift=3;
      tick(); @(negedge clk); req_valid=0;
      repeat(delay_cycles) tick();
      @(negedge clk); rst_n=0; tick();
      if(rsp_valid || req_ready || done || max_valid) $fatal(1,"reset pending arithmetic");
      @(negedge clk); rst_n=1;
      repeat(6) begin tick(); if(rsp_valid) $fatal(1,"stale requant after reset"); end
    end
    $display("[PASS] tb_tinynpu_arithmetic checks=%0d", checks);
    $finish;
  end
  initial begin #1000000; $fatal(1,"arithmetic timeout"); end
endmodule
