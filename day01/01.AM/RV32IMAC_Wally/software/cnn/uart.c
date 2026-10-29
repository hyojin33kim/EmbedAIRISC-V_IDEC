// Wally UART를 초기화하고 문자를 송수신한다.
#include "uart.h"

void uart_init(void) {
    UART_LCR = 0x03;
}

void uwrite_int8(int8_t c) {
    while (!UTRAN_CTRL) ;
    UTRAN_DATA = c;
}

void uwrite_int8s(const int8_t* s) {
    for (int i = 0; s[i] != '\0'; i++) {
        uwrite_int8(s[i]);
    }
}

int8_t uread_int8(void) {
    while (!URECV_CTRL) ;
    int8_t ch = URECV_DATA;
    if (ch == '\x0d') {
        uwrite_int8s((const int8_t*)"\r\n");
    } else {
        uwrite_int8(ch);
    }
    return ch;
}

int8_t uread_int8_noecho(void) {
    while (!URECV_CTRL) ;
    int8_t ch = URECV_DATA;
    return ch;
}
