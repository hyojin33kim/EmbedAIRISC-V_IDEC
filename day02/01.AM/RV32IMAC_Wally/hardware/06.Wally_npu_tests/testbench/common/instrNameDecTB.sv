///////////////////////////////////////////
// instrNameDecTB.sv
//
// Purpose: decode instruction_name of function
//
// A component of the Wally configurable RISC-V project.
//
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

// decode the instruction instruction_name, to help the test bench
module instrNameDecTB #(parameter XLEN) (
  input  logic [31:0] instr,
  output string       instruction_name);

  logic [6:0] op;
  logic       funct1;
  logic [1:0] funct2;
  logic [2:0] funct3;
  logic [4:0] funct5;
  logic [6:0] funct7;
  logic [11:0] imm;
  logic [4:0] rs2, rd, CRrs2;
  logic [1:0] compressedOp;
  logic [5:0] compressed15_10;


  assign op = instr[6:0];
  assign funct1 = instr[6];
  assign funct2 = instr[6:5];
  assign funct3 = instr[14:12];
  assign funct5 = instr[6:2];
  assign funct7 = instr[31:25];
  assign imm = instr[31:20];
  assign rs2 = instr[24:20];
  assign rd = instr[11:7];
  assign compressedOp = instr[1:0];
  assign compressed15_10 = instr[15:10];
  assign CRrs2 = instr[6:2];

  // it would be nice to add the operands to the instruction_name
  // create another variable called decoded

  always_comb
    case (compressedOp)
      2'b00:
        casez (compressed15_10)
          6'b000???: if (instr[12:5] != 8'b0) instruction_name = "C.ADDI4SPN";
                     else if(compressed15_10 == 6'b000000 & op == 7'b0000000 & funct3 == 3'b000) instruction_name = "BAD";
          6'b010???: instruction_name = "C.LW";
          6'b110???: instruction_name = "C.SW";
          6'b011???: if (XLEN == 32'd32) instruction_name = "C.FLW";
                     else instruction_name = "C.LD";
          6'b111???: if (XLEN == 32'd32) instruction_name = "C.FSW";
                     else instruction_name = "C.SD";
          6'b100000: instruction_name = "C.LBU";
          6'b100001: if (funct1 == 1'b1) instruction_name = "C.LH";
                     else if (funct1 == 1'b0) instruction_name = "C.LHU";
          6'b100010: instruction_name = "C.SB";
          6'b100011: if (funct1 == 1'b0) instruction_name = "C.SH";
          6'b001???: instruction_name = "C.FLD";
          6'b101???: instruction_name = "C.FSD";
          default: instruction_name = "ILLEGAL";
        endcase
      2'b01:
        casez (compressed15_10)
          6'b000???: if (instr[12:10] == 3'b0 & rd == 5'b00000 & instr[6:2] == 5'b00000) instruction_name = "C.NOP";
                     else if (rd != 5'b00000 & instr[6:2] != 5'b00000) instruction_name = "C.ADDI";
          6'b010???: if (rd != 5'b00000) instruction_name = "C.LI";
          6'b011???: if (rd != 5'b00000 & rd != 5'b00010 & instr[6:2] != 5'b00000) instruction_name = "C.LUI";
                     else if (rd == 5'b00010 & instr[6:2] != 5'b00000) instruction_name = "C.ADDI16SP";
          6'b100?00: instruction_name = "C.SRLI";
          6'b100?01: instruction_name = "C.SRAI";
          6'b100?10: instruction_name = "C.ANDI";
          6'b100011: if (funct2 == 2'b00) instruction_name = "C.SUB";
                     else if (funct2 == 2'b01) instruction_name = "C.XOR";
                     else if (funct2 == 2'b10) instruction_name = "C.OR";
                     else if (funct2 == 2'b11) instruction_name = "C.AND";
          6'b101???: instruction_name = "C.J";
          6'b110???: instruction_name = "C.BEQZ";
          6'b111???: instruction_name = "C.BNEZ";
          6'b001???: if (XLEN == 32'd32) instruction_name = "C.JAL";
                     else if (XLEN == 32'd64 & rd != 5'b00000) instruction_name = "C.ADDIW";
          6'b100111: if (XLEN == 32'd64 & funct2 == 2'b00) instruction_name = "C.SUBW";
                     else if (XLEN == 32'd64 & funct2 == 2'b01) instruction_name = "C.ADDW";
                     else if (funct5 == 5'b11000) instruction_name = "C.ZEXT.B";
                     else if (funct5 == 5'b11001) instruction_name = "C.SEXT.B";
                     else if (funct5 == 5'b11010) instruction_name = "C.ZEXT.H";
                     else if (funct5 == 5'b11011) instruction_name = "C.SEXT.H";
                     else if (funct5 == 5'b11101) instruction_name = "C.NOT";
                     else if (funct2 == 2'b10) instruction_name = "C.MUL";
                     else if (funct5 == 5'b11100) instruction_name = "C.ZEXT.W";
          default: instruction_name = "ILLEGAL";
        endcase
      2'b10:
        casez (compressed15_10)
          6'b000???: if (rd != 5'b00000) instruction_name = "C.SLLI";
          6'b010???: if (rd != 5'b00000) instruction_name = "C.LWSP";
          6'b1000??: if (rd != 5'b00000 & CRrs2 == 5'b00000 ) instruction_name = "C.JR";
                     else if (rd != 5'b00000 & CRrs2 != 5'b00000 ) instruction_name = "C.MV";
          6'b1001??: if (rd == 5'b00000 & CRrs2 == 5'b00000 ) instruction_name = "C.EBREAK";
                     else if (rd != 5'b00000 & CRrs2 == 5'b00000 ) instruction_name = "C.JALR";
                     else if (rd != 5'b00000 & CRrs2 != 5'b00000 ) instruction_name = "C.ADD";
          6'b110???: instruction_name = "C.SWSP";
          6'b011???: if (XLEN == 32'd32) instruction_name = "C.FLWSP";
                     else if (rd != 5'b00000) instruction_name = "C.LDSP";
          6'b111???: if (XLEN == 32'd32) instruction_name = "C.FSWSP";
                     else instruction_name = "C.SDSP";
          6'b001???: instruction_name = "C.FLDSP";
          6'b101???: instruction_name = "C.FSDSP";
          default: instruction_name = "ILLEGAL";
        endcase
      2'b11:
        casez({op, funct3})
          10'b0000011_000: instruction_name = "LB";
          10'b0000011_001: instruction_name = "LH";
          10'b0000011_010: instruction_name = "LW";
          10'b0000011_011: instruction_name = "LD";
          10'b0000011_100: instruction_name = "LBU";
          10'b0000011_101: instruction_name = "LHU";
          10'b0000011_110: instruction_name = "LWU";
          10'b0010011_000: if (instr[31:15] == 0 & instr[11:7] ==0) instruction_name = "NOP/FLUSH";
                          else                                      instruction_name = "ADDI";
          10'b0010011_001: if (funct7[6:1] == 6'b000000) instruction_name = "SLLI";
                          else if (funct7[6:1] == 6'b010010) instruction_name = "BCLRI";
                          else if (funct7[6:1] == 6'b011010) instruction_name = "BINVI";
                          else if (funct7[6:1] == 6'b001010) instruction_name = "BSETI";
                          else if (funct7 == 7'b0000100 & rs2 == 5'b01111) instruction_name = "ZIP";
                          else if (funct7 == 7'b0011000 & rs2 == 5'b00000) instruction_name = "AES64IM";
                          else if (funct7 == 7'b0011000 & rs2[4] == 1'b1) instruction_name = "AES64KS1I";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00010) instruction_name = "SHA256SIG0";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00011) instruction_name = "SHA256SIG1";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00000) instruction_name = "SHA256SUM0";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00001) instruction_name = "SHA256SUM1";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00110) instruction_name = "SHA512SIG0";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00111) instruction_name = "SHA512SIG1";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00100) instruction_name = "SHA512SUM0";
                          else if (funct7 == 7'b0001000 & rs2 == 5'b00101) instruction_name = "SHA512SUM1";
                          else if (funct7 == 7'b0110000) begin
                            case (rs2)
                              5'b00000: instruction_name = "CLZ";
                              5'b00010: instruction_name = "CPOP";
                              5'b00001: instruction_name = "CTZ";
                              5'b00100: instruction_name = "SEXT.B";
                              5'b00101: instruction_name = "SEXT.H";
                              default:  instruction_name = "ILLEGAL";
                            endcase
                          end else                      instruction_name = "ILLEGAL";
          10'b0010011_010: instruction_name = "SLTI";
          10'b0010011_011: instruction_name = "SLTIU";
          10'b0010011_100: instruction_name = "XORI";
          10'b0010011_101: if (funct7[6:1] == 6'b000000)      instruction_name = "SRLI";
                          else if (funct7[6:1] == 6'b010000) instruction_name = "SRAI";
                          else if (funct7[6:1] == 6'b011010 & rs2 == 5'b11000) instruction_name = "REV8";
                          else if (funct7[6:1] == 6'b011000) instruction_name = "RORI";
                          else if (funct7[6:1] == 6'b010010) instruction_name = "BEXTI";
                          else if (funct7 == 7'b0010100 & rs2 == 5'b00111) instruction_name = "ORC.B";
                          else if (imm == 12'b011010000111) instruction_name = "BREV8";
                          else if (funct7 == 7'b0000100 & rs2 == 5'b01111) instruction_name = "UNZIP";
                          else                           instruction_name = "ILLEGAL";
          10'b0010011_110: if      (rd == 0 & rs2 == 0) instruction_name = "PREFETCH.I";
                          else if (rd == 0 & rs2 == 1) instruction_name = "PREFETCH.R";
                          else if (rd == 0 & rs2 == 3) instruction_name = "PREFETCH.W";
                          else                         instruction_name = "ORI";
          10'b0010011_111: instruction_name = "ANDI";
          10'b0010111_???: instruction_name = "AUIPC";
          10'b0100011_000: instruction_name = "SB";
          10'b0100011_001: instruction_name = "SH";
          10'b0100011_010: instruction_name = "SW";
          10'b0100011_011: instruction_name = "SD";
          10'b0011011_000: instruction_name = "ADDIW";
          10'b0011011_001: if      (funct7 == 7'b0000000 )instruction_name = "SLLIW";
                          else if (funct7[6:1] == 6'b000010) instruction_name = "SLLI.UW";
                          else if (funct7 == 7'b0110000) begin
                            case (rs2)
                              5'b00000:                  instruction_name = "CLZW";
                              5'b00010:                  instruction_name = "CPOPW";
                              5'b00001:                  instruction_name = "CTZW";
                              default:                   instruction_name = "ILLEGAL";
                            endcase
                          end else                       instruction_name = "ILLEGAL";
          10'b0011011_101: if      (funct7 == 7'b0000000) instruction_name = "SRLIW";
                          else if (funct7 == 7'b0100000) instruction_name = "SRAIW";
                          else if (funct7 == 7'b0110000) instruction_name = "RORIW";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_000: if      (funct7 == 7'b0000000) instruction_name = "ADDW";
                          else if (funct7 == 7'b0100000) instruction_name = "SUBW";
                          else if (funct7 == 7'b0000001) instruction_name = "MULW";
                          else if (funct7 == 7'b0000100) instruction_name = "ADD.UW";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_001: if      (funct7 == 7'b0000000) instruction_name = "SLLW";
                          else if (funct7 == 7'b0000001) instruction_name = "DIVW";
                          else if (funct7 == 7'b0110000) instruction_name = "ROLW";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_010: if      (funct7 == 7'b0010000) instruction_name = "SH1ADD.UW";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_100: if      (funct7 == 7'b0010000) instruction_name = "SH2ADD.UW";
                          else if (funct7 == 7'b0000100) instruction_name = "ZEXT.H";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_101: if      (funct7 == 7'b0000000) instruction_name = "SRLW";
                          else if (funct7 == 7'b0100000) instruction_name = "SRAW";
                          else if (funct7 == 7'b0000001) instruction_name = "DIVUW";
                          else if (funct7 == 7'b0110000) instruction_name = "RORW";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_110: if      (funct7 == 7'b0000001) instruction_name = "REMW";
                          else if (funct7 == 7'b0010000) instruction_name = "SH3ADD.UW";
                          else                           instruction_name = "ILLEGAL";
          10'b0111011_111: if      (funct7 == 7'b0000001) instruction_name = "REMUW";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_000: if      (funct7 == 7'b0000000) instruction_name = "ADD";
                          else if (funct7 == 7'b0000001) instruction_name = "MUL";
                          else if (funct7 == 7'b0100000) instruction_name = "SUB";
                          else if (funct7[4:0] == 5'b10101) instruction_name = "AES32DSI";
                          else if (funct7[4:0] == 5'b10111) instruction_name = "AES32DSMI";
                          else if (funct7 == 7'b0011101)    instruction_name = "AES64DS";
                          else if (funct7 == 7'b0011111)    instruction_name = "AES64DSM";
                          else if (funct7[4:0] == 5'b10001) instruction_name = "AES32ESI";
                          else if (funct7[4:0] == 5'b10011) instruction_name = "AES32ESMI";
                          else if (funct7 == 7'b0011001)    instruction_name = "AES64ES";
                          else if (funct7 == 7'b0011011)    instruction_name = "AES64ESM";
                          else if (funct7 == 7'b0111111)    instruction_name = "AES64KS2";
                          else if (funct7 == 7'b0101110) instruction_name = "SHA512SIG0H";
                          else if (funct7 == 7'b0101010) instruction_name = "SHA512SIG0L";
                          else if (funct7 == 7'b0101111) instruction_name = "SHA512SIG1H";
                          else if (funct7 == 7'b0101011) instruction_name = "SHA512SIG1L";
                          else if (funct7 == 7'b0101000) instruction_name = "SHA512SUM0R";
                          else if (funct7 == 7'b0101001) instruction_name = "SHA512SUM1R";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_001: if      (funct7 == 7'b0000000) instruction_name = "SLL";
                          else if (funct7 == 7'b0000001) instruction_name = "MULH";
                          else if (funct7 == 7'b0110000) instruction_name = "ROL";
                          else if (funct7 == 7'b0000101) instruction_name = "CLMUL";
                          else if (funct7 == 7'b0100100) instruction_name = "BCLR";
                          else if (funct7 == 7'b0110100) instruction_name = "BINV";
                          else if (funct7 == 7'b0010100) instruction_name = "BSET";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_010: if      (funct7 == 7'b0000000) instruction_name = "SLT";
                          else if (funct7 == 7'b0000001) instruction_name = "MULHSU";
                          else if (funct7 == 7'b0010000) instruction_name = "SH1ADD";
                          else if (funct7 == 7'b0000101) instruction_name = "CLMULR";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_011: if      (funct7 == 7'b0000000) instruction_name = "SLTU";
                          else if (funct7 == 7'b0000001) instruction_name = "MULHU";
                          else if (funct7 == 7'b0000101) instruction_name = "CLMULH";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_100: if      (funct7 == 7'b0000000) instruction_name = "XOR";
                          else if (funct7 == 7'b0000001) instruction_name = "DIV";
                          else if (funct7 == 7'b0010000) instruction_name = "SH2ADD";
                          else if (funct7 == 7'b0000101) instruction_name = "MIN";
                          else if (funct7 == 7'b0100000) instruction_name = "ORN";
                          else if (funct7 == 7'b0000100 & rs2 == 5'b00000) instruction_name = "ZEXT.H";
                          else if (funct7 == 7'b0000100 & op == 7'b0110011) instruction_name = "PACK";
                          else if (funct7 == 7'b0000100 & op == 7'b0111011) instruction_name = "PACKW";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_101: if      (funct7 == 7'b0000000) instruction_name = "SRL";
                          else if (funct7 == 7'b0000001) instruction_name = "DIVU";
                          else if (funct7 == 7'b0100000) instruction_name = "SRA";
                          else if (funct7 == 7'b0000101) instruction_name = "MINU";
                          else if (funct7 == 7'b0110000) instruction_name = "ROR";
                          else if (funct7 == 7'b0100100) instruction_name = "BEXT";
                          else if (funct7 == 7'b0000111) instruction_name = "CZERO.EQZ";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_110: if      (funct7 == 7'b0000000) instruction_name = "OR";
                          else if (funct7 == 7'b0000001) instruction_name = "REM";
                          else if (funct7 == 7'b0010000) instruction_name = "SH3ADD";
                          else if (funct7 == 7'b0000101) instruction_name = "MAX";
                          else if (funct7 == 7'b0100000) instruction_name = "XNOR";
                          else                           instruction_name = "ILLEGAL";
          10'b0110011_111: if      (funct7 == 7'b0000000) instruction_name = "AND";
                          else if (funct7 == 7'b0000001) instruction_name = "REMU";
                          else if (funct7 == 7'b0000101) instruction_name = "MAXU";
                          else if (funct7 == 7'b0100000) instruction_name = "ANDN";
                          else if (funct7 == 7'b0000111) instruction_name = "CZERO.NEZ";
                          else                           instruction_name = "ILLEGAL";
          10'b0110111_???: instruction_name = "LUI";
          10'b1100011_000: instruction_name = "BEQ";
          10'b1100011_001: instruction_name = "BNE";
          10'b1100011_100: instruction_name = "BLT";
          10'b1100011_101: instruction_name = "BGE";
          10'b1100011_110: instruction_name = "BLTU";
          10'b1100011_111: instruction_name = "BGEU";
          10'b1100111_000: instruction_name = "JALR";
          10'b1101111_???: instruction_name = "JAL";
          10'b1110011_000: if      (imm == 0) instruction_name = "ECALL";
                          else if (imm == 1) instruction_name = "EBREAK";
                          else if (imm == 258) instruction_name = "SRET";
                          else if (imm == 770) instruction_name = "MRET";
                          else if (funct7 == 9) instruction_name = "SFENCE.VMA";
                          else if (funct7 == 11) instruction_name = "SINVAL.VMA";
                          else if (funct7 == 12 & rs2 == 0) instruction_name = "SFENCE.W.INVAL";
                          else if (funct7 == 12 & rs2 == 1) instruction_name = "SFENCE.INVAL.IR";
                          else if (imm == 259) instruction_name = "WFI";
                          else if (imm == 261) instruction_name = "WFI";
                          else              instruction_name = "ILLEGAL";
          10'b1110011_001: instruction_name = "CSRRW";
          10'b1110011_010: instruction_name = "CSRRS";
          10'b1110011_011: instruction_name = "CSRRC";
          10'b1110011_101: instruction_name = "CSRRWI";
          10'b1110011_110: instruction_name = "CSRRSI";
          10'b1110011_111: instruction_name = "CSRRCI";
          10'b0101111_010: if      (funct7[6:2] == 5'b00010) instruction_name = "LR.W";
                          else if (funct7[6:2] == 5'b00011) instruction_name = "SC.W";
                          else if (funct7[6:2] == 5'b00001) instruction_name = "AMOSWAP.W";
                          else if (funct7[6:2] == 5'b00000) instruction_name = "AMOADD.W";
                          else if (funct7[6:2] == 5'b00100) instruction_name = "AMOAXOR.W";
                          else if (funct7[6:2] == 5'b01100) instruction_name = "AMOAND.W";
                          else if (funct7[6:2] == 5'b01000) instruction_name = "AMOOR.W";
                          else if (funct7[6:2] == 5'b10000) instruction_name = "AMOMIN.W";
                          else if (funct7[6:2] == 5'b10100) instruction_name = "AMOMAX.W";
                          else if (funct7[6:2] == 5'b11000) instruction_name = "AMOMINU.W";
                          else if (funct7[6:2] == 5'b11100) instruction_name = "AMOMAXU.W";
                          else                              instruction_name = "ILLEGAL";
          10'b0101111_011: if      (funct7[6:2] == 5'b00010) instruction_name = "LR.D";
                          else if (funct7[6:2] == 5'b00011) instruction_name = "SC.D";
                          else if (funct7[6:2] == 5'b00001) instruction_name = "AMOSWAP.D";
                          else if (funct7[6:2] == 5'b00000) instruction_name = "AMOADD.D";
                          else if (funct7[6:2] == 5'b00100) instruction_name = "AMOAXOR.D";
                          else if (funct7[6:2] == 5'b01100) instruction_name = "AMOAND.D";
                          else if (funct7[6:2] == 5'b01000) instruction_name = "AMOOR.D";
                          else if (funct7[6:2] == 5'b10000) instruction_name = "AMOMIN.D";
                          else if (funct7[6:2] == 5'b10100) instruction_name = "AMOMAX.D";
                          else if (funct7[6:2] == 5'b11000) instruction_name = "AMOMINU.D";
                          else if (funct7[6:2] == 5'b11100) instruction_name = "AMOMAXU.D";
                          else                              instruction_name = "ILLEGAL";
          10'b0001111_000: instruction_name = "FENCE";
          10'b0001111_001: instruction_name = "FENCE.I";
          10'b0001111_010: if      (instr[31:20] == 12'd0) instruction_name = "CBO.INVAL";
                          else if (instr[31:20] == 12'd1) instruction_name = "CBO.CLEAN";
                          else if (instr[31:20] == 12'd2) instruction_name = "CBO.FLUSH";
                          else if (instr[31:20] == 12'd4) instruction_name = "CBO.ZERO";
                          else                            instruction_name = "ILLEGAL";
          10'b1000011_???: instruction_name = "FMADD";
          10'b1000111_???: instruction_name = "FMSUB";
          10'b1001011_???: instruction_name = "FNMSUB";
          10'b1001111_???: instruction_name = "FNMADD";
          10'b1010011_???: if      (funct7[6:2] == 5'b00000) instruction_name = "FADD";
                          else if (funct7[6:2] == 5'b00001) instruction_name = "FSUB";
                          else if (funct7[6:2] == 5'b00010) instruction_name = "FMUL";
                          else if (funct7[6:2] == 5'b00011) instruction_name = "FDIV";
                          else if (funct7[6:2] == 5'b01011) instruction_name = "FSQRT";
                          else if (funct7 == 7'b1100000 & rs2 == 5'b00000) instruction_name = "FCVT.W.S";
                          else if (funct7 == 7'b1100000 & rs2 == 5'b00001) instruction_name = "FCVT.WU.S";
                          else if (funct7 == 7'b1100000 & rs2 == 5'b00010) instruction_name = "FCVT.L.S";
                          else if (funct7 == 7'b1100000 & rs2 == 5'b00011) instruction_name = "FCVT.LU.S";
                          else if (funct7 == 7'b1101000 & rs2 == 5'b00000) instruction_name = "FCVT.S.W";
                          else if (funct7 == 7'b1101000 & rs2 == 5'b00001) instruction_name = "FCVT.S.WU";
                          else if (funct7 == 7'b1101000 & rs2 == 5'b00010) instruction_name = "FCVT.S.L";
                          else if (funct7 == 7'b1101000 & rs2 == 5'b00011) instruction_name = "FCVT.S.LU";
                          else if (funct7 == 7'b1100001 & rs2 == 5'b00000) instruction_name = "FCVT.W.D";
                          else if (funct7 == 7'b1100001 & rs2 == 5'b00001) instruction_name = "FCVT.WU.D";
                          else if (funct7 == 7'b1100001 & rs2 == 5'b00010) instruction_name = "FCVT.L.D";
                          else if (funct7 == 7'b1100001 & rs2 == 5'b00011) instruction_name = "FCVT.LU.D";
                          else if (funct7 == 7'b1101001 & rs2 == 5'b00000) instruction_name = "FCVT.D.W";
                          else if (funct7 == 7'b1101001 & rs2 == 5'b00001) instruction_name = "FCVT.D.WU";
                          else if (funct7 == 7'b1101001 & rs2 == 5'b00010) instruction_name = "FCVT.D.L";
                          else if (funct7 == 7'b1101001 & rs2 == 5'b00011) instruction_name = "FCVT.D.LU";
                          else if (funct7 == 7'b0100000 & rs2 == 5'b00001) instruction_name = "FCVT.S.D";
                          else if (funct7 == 7'b0100001 & rs2 == 5'b00000) instruction_name = "FCVT.D.S";
                          else if (funct7 == 7'b1100010 & rs2 == 5'b00000) instruction_name = "FCVT.W.H";
                          else if (funct7 == 7'b1100010 & rs2 == 5'b00001) instruction_name = "FCVT.WU.H";
                          else if (funct7 == 7'b1100010 & rs2 == 5'b00010) instruction_name = "FCVT.L.H";
                          else if (funct7 == 7'b1100010 & rs2 == 5'b00011) instruction_name = "FCVT.LU.H";
                          else if (funct7 == 7'b1101010 & rs2 == 5'b00000) instruction_name = "FCVT.H.W";
                          else if (funct7 == 7'b1101010 & rs2 == 5'b00001) instruction_name = "FCVT.H.WU";
                          else if (funct7 == 7'b1101010 & rs2 == 5'b00010) instruction_name = "FCVT.H.L";
                          else if (funct7 == 7'b1101010 & rs2 == 5'b00011) instruction_name = "FCVT.H.LU";
                          else if (funct7 == 7'b1100011 & rs2 == 5'b00000) instruction_name = "FCVT.W.Q";
                          else if (funct7 == 7'b1100011 & rs2 == 5'b00001) instruction_name = "FCVT.WU.Q";
                          else if (funct7 == 7'b1100011 & rs2 == 5'b00010) instruction_name = "FCVT.L.Q";
                          else if (funct7 == 7'b1100011 & rs2 == 5'b00011) instruction_name = "FCVT.LU.Q";
                          else if (funct7 == 7'b1101011 & rs2 == 5'b00000) instruction_name = "FCVT.Q.W";
                          else if (funct7 == 7'b1101011 & rs2 == 5'b00001) instruction_name = "FCVT.Q.WU";
                          else if (funct7 == 7'b1101011 & rs2 == 5'b00010) instruction_name = "FCVT.Q.L";
                          else if (funct7 == 7'b1101011 & rs2 == 5'b00011) instruction_name = "FCVT.Q.LU";
                          else if (funct7 == 7'b0100000 & rs2 == 5'b00001) instruction_name = "FCVT.S.D";
                          else if (funct7 == 7'b0100000 & rs2 == 5'b00010) instruction_name = "FCVT.S.H";
                          else if (funct7 == 7'b0100000 & rs2 == 5'b00011) instruction_name = "FCVT.S.Q";
                          else if (funct7 == 7'b0100001 & rs2 == 5'b00000) instruction_name = "FCVT.D.S";
                          else if (funct7 == 7'b0100001 & rs2 == 5'b00010) instruction_name = "FCVT.D.H";
                          else if (funct7 == 7'b0100001 & rs2 == 5'b00011) instruction_name = "FCVT.D.Q";
                          else if (funct7 == 7'b0100010 & rs2 == 5'b00000) instruction_name = "FCVT.H.S";
                          else if (funct7 == 7'b0100010 & rs2 == 5'b00001) instruction_name = "FCVT.H.D";
                          else if (funct7 == 7'b0100010 & rs2 == 5'b00011) instruction_name = "FCVT.H.Q";
                          else if (funct7 == 7'b0100011 & rs2 == 5'b00000) instruction_name = "FCVT.Q.S";
                          else if (funct7 == 7'b0100011 & rs2 == 5'b00001) instruction_name = "FCVT.Q.D";
                          else if (funct7 == 7'b0100011 & rs2 == 5'b00010) instruction_name = "FCVT.Q.H";
                          else if (funct7 == 7'b1110000 & rs2 == 5'b00000 & funct3 == 3'b000) instruction_name = "FMV.X.W";
                          else if (funct7 == 7'b1111000 & rs2 == 5'b00000 & funct3 == 3'b000) instruction_name = "FMV.W.X";
                          else if (funct7 == 7'b1110001 & rs2 == 5'b00000 & funct3 == 3'b000) instruction_name = "FMV.X.D";
                          else if (funct7 == 7'b1111001 & rs2 == 5'b00000 & funct3 == 3'b000) instruction_name = "FMV.D.X";
                          else if (funct7 == 7'b1110010 & rs2 == 5'b00000 & funct3 == 3'b000) instruction_name = "FMV.X.H";
                          else if (funct7 == 7'b1111010 & rs2 == 5'b00000 & funct3 == 3'b000) instruction_name = "FMV.H.X";
                          else if (funct7[6:2] == 5'b00100 & funct3 == 3'b000) instruction_name = "FSGNJ";
                          else if (funct7[6:2] == 5'b00101 & funct3 == 3'b000) instruction_name = "FMIN";
                          else if (funct7[6:2] == 5'b10100 & funct3 == 3'b000) instruction_name = "FLE";
                          else if (funct7[6:2] == 5'b00100 & funct3 == 3'b001) instruction_name = "FSGNJN";
                          else if (funct7[6:2] == 5'b00101 & funct3 == 3'b001) instruction_name = "FMAX";
                          else if (funct7[6:2] == 5'b10100 & funct3 == 3'b001) instruction_name = "FLT";
                          else if (funct7[6:2] == 5'b11100 & funct3 == 3'b001) instruction_name = "FCLASS";
                          else if (funct7[6:2] == 5'b00100 & funct3 == 3'b010) instruction_name = "FSGNJX";
                          else if (funct7[6:2] == 5'b10100 & funct3 == 3'b010) instruction_name = "FEQ";
                          else if (funct7[6:2] == 5'b11110 & funct3 == 3'b000 & rs2 == 5'b00001) instruction_name = "FLI";
                          else if (funct7[6:2] == 5'b00101 & funct3 == 3'b010) instruction_name = "FMINM";
                          else if (funct7[6:2] == 5'b00101 & funct3 == 3'b011) instruction_name = "FMAXM";
                          else if (funct7[6:2] == 5'b01000 & rs2 == 5'b00100) instruction_name = "FROUND";
                          else if (funct7[6:2] == 5'b01000 & rs2 == 5'b00101) instruction_name = "FROUNDNX";
                          else if (funct7[6:2] == 5'b10100 & funct3 == 3'b100) instruction_name = "FLEQ";
                          else if (funct7[6:2] == 5'b10100 & funct3 == 3'b101) instruction_name = "FLTQ";
                          else if (funct7 == 7'b1110001 & funct3 == 3'b000 & rs2 == 5'b00001) instruction_name = "FMVH.X.D";
                          else if (funct7 == 7'b1110011 & funct3 == 3'b000 & rs2 == 5'b00001) instruction_name = "FMVH.X.Q";
                          else if (funct7 == 7'b1011001 & funct3 == 3'b000) instruction_name = "FMVP.D.X";
                          else if (funct7 == 7'b1011011 & funct3 == 3'b000) instruction_name = "FMVP.Q.X";
                          else if (funct7 == 7'b1100001 & funct3 == 3'b001 & rs2 == 5'b01000) instruction_name = "FCVTMOD.W.D";
                          else                              instruction_name = "ILLEGAL";
          10'b0000111_001: instruction_name = "FLH";
          10'b0000111_010: instruction_name = "FLW";
          10'b0000111_011: instruction_name = "FLD";
          10'b0000111_100: instruction_name = "FLQ";
          10'b0100111_001: instruction_name = "FSH";
          10'b0100111_010: instruction_name = "FSW";
          10'b0100111_011: instruction_name = "FSD";
          10'b0100111_100: instruction_name = "FSQ";
          default:         instruction_name = "ILLEGAL";
        endcase
    endcase
endmodule
