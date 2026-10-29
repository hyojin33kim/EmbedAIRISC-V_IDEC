// 대기와 오류를 주입하고 데이터 단계에서만 접근하는 AHB SRAM 검증 모델이다.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module ahb_sram_model #(
  parameter int ADDR_W = 34,
  parameter logic [ADDR_W-1:0] BASE_ADDR = 34'h080000000,
  parameter int BYTES = 65536
) (
  input logic clk, rst_n,
  input logic [ADDR_W-1:0] HADDR,
  input logic HWRITE,
  input logic [2:0] HSIZE, HBURST,
  input logic [1:0] HTRANS,
  input logic [31:0] HWDATA,
  input logic [3:0] HWSTRB,
  output logic [31:0] HRDATA,
  output logic HREADY, HRESP,
  input logic [5:0] wait_cycles,
  input logic random_wait,
  input logic error_enable, error_write,
  input logic [ADDR_W-1:0] error_addr
);
  byte unsigned mem [0:BYTES-1];
  logic d_valid, d_write, d_error, error_terminal;
  logic [ADDR_W-1:0] d_addr;
  logic [2:0] d_size;
  logic [5:0] wait_left;
  logic [31:0] random_state;
  integer accepted_count, read_count, write_count, write_bytes, error_count;
  integer index;
  logic [3:0] expected_strobe;
  logic held_wait;
  logic [ADDR_W+40:0] held_bus;
  wire [ADDR_W+40:0] current_bus = {HADDR,HWRITE,HSIZE,HBURST,HTRANS,HWDATA};
  logic [3:0] held_strobe;

  always_comb begin
    HREADY = !d_valid || ((wait_left == 0) && (!d_error || error_terminal));
    HRESP = d_valid && (wait_left == 0) && d_error;
    HRDATA = 32'b0;
    index = int'((d_addr - BASE_ADDR) & ~ADDR_W'(3));
    if (d_valid && !d_write && !d_error && index >= 0 && index + 3 < BYTES)
      for (int lane = 0; lane < 4; lane++) HRDATA[8*lane +: 8] = mem[index+lane];
    expected_strobe = 4'b0;
    if (d_valid && d_write) begin
      case (d_size)
        3'd0: expected_strobe = 4'b0001 << d_addr[1:0];
        3'd1: expected_strobe = 4'b0011 << d_addr[1:0];
        3'd2: expected_strobe = 4'b1111;
        default: expected_strobe = 4'b0;
      endcase
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_valid <= 0; d_write <= 0; d_addr <= '0; d_size <= 0;
      d_error <= 0; error_terminal <= 0; wait_left <= 0;
      random_state <= 32'h7a19d3e5;
      accepted_count <= 0; read_count <= 0; write_count <= 0;
      write_bytes <= 0; error_count <= 0;
      held_wait <= 0; held_bus <= '0; held_strobe <= '0;
    end else begin
      if (held_wait && current_bus !== held_bus)
        $fatal(1, "AHB address/control/data changed during normal wait");
      if (held_wait && HWSTRB !== held_strobe)
        $fatal(1, "AHB write strobe changed during normal wait");
      held_wait <= !HREADY && !HRESP;
      held_bus <= current_bus;
      held_strobe <= HWSTRB;
      if (d_valid && wait_left != 0) wait_left <= wait_left - 1'b1;
      if (d_valid && wait_left == 0 && d_error && !error_terminal)
        error_terminal <= 1;
      if (d_valid && HREADY) begin
        if (HRESP) error_count <= error_count + 1;
        else if (d_write) begin
          if (HWSTRB !== expected_strobe)
            $fatal(1, "AHB strobe address=%h actual=%h expected=%h",d_addr,HWSTRB,expected_strobe);
          for (int lane = 0; lane < 4; lane++) begin
            if (HWSTRB[lane]) mem[index+lane] <= HWDATA[8*lane +: 8];
            else if (HWDATA[8*lane +: 8] !== 8'b0)
              $fatal(1, "AHB inactive write lane is not zero");
          end
          write_count <= write_count + 1;
          write_bytes <= write_bytes + (1 << d_size);
        end else read_count <= read_count + 1;
      end
      if (HREADY) begin
        d_valid <= HTRANS[1];
        error_terminal <= 0;
        if (HTRANS[1]) begin
          if (HSIZE > 2 || (HADDR & ((ADDR_W'(1) << HSIZE)-1)) != 0)
            $fatal(1, "AHB invalid alignment or size at %h", HADDR);
          if (HADDR < BASE_ADDR || HADDR + (ADDR_W'(1) << HSIZE) > BASE_ADDR + ADDR_W'(BYTES))
            $fatal(1, "AHB access outside modeled SRAM at %h", HADDR);
          d_addr <= HADDR; d_write <= HWRITE; d_size <= HSIZE;
          d_error <= error_enable && error_write == HWRITE && error_addr == HADDR;
          wait_left <= random_wait ? {3'b0,random_state[2:0]} : wait_cycles;
          random_state <= {random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
          accepted_count <= accepted_count + 1;
        end
      end
    end
  end
endmodule
