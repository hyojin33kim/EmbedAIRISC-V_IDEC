// Wally UART 레지스터와 송수신 함수를 선언한다.
#ifndef UART_H_
#define UART_H_

#include <stdint.h>

#define UART_BASE   0x10000000
#define UART_RBR    (*((volatile uint8_t*)(UART_BASE + 0)))
#define UART_THR    (*((volatile uint8_t*)(UART_BASE + 0)))
#define UART_LCR    (*((volatile uint8_t*)(UART_BASE + 3)))
#define UART_LSR    (*((volatile uint8_t*)(UART_BASE + 5)))

#define URECV_CTRL  (UART_LSR & 0x01)   // LSR[0] DR
#define URECV_DATA  (UART_RBR)
#define UTRAN_CTRL  (UART_LSR & 0x20)   // LSR[5] THRE
#define UTRAN_DATA  (UART_THR)

void uart_init(void);

void uwrite_int8(int8_t c);

void uwrite_int8s(const int8_t* s);

int8_t uread_int8(void);

int8_t uread_int8_noecho(void);

#endif
