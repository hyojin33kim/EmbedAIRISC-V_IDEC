// 기존 TB 의 `ifdef FSDB 블록과 같은 역할 — sim_define.v 로 제어
module wave_dump;
`ifdef FSDB
  initial begin
    $fsdbDumpfile("wave.fsdb");
    $fsdbDumpvars(0, testbench);
  end
`endif
endmodule
