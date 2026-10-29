# Wally 검증 펌웨어의 스택을 설정하고 C 진입점으로 분기한다.
.section .text.start
.globl _start
_start:
  la sp, _stack_top
  call main
1:
  j 1b
