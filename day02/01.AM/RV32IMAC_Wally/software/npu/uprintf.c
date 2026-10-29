// 정수 형식 문자열을 UART로 출력한다.
#include <stdint.h>
#include "uart.h"
#include "uprintf.h"

static int out_cnt;

static void put(char c) { uwrite_int8((int8_t)c); out_cnt++; }

static void put_pad(char c, int n) { while (n-- > 0) put(c); }

static void put_num(uint32_t v, int base, int upper, int neg, int width, char pad, int left) {
    char buf[12];
    const char* dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;
    do { buf[n++] = dig[v % base]; v /= base; } while (v);
    int len = n + (neg ? 1 : 0);
    if (!left && pad == ' ') put_pad(' ', width - len);
    if (neg) put('-');
    if (!left && pad == '0') put_pad('0', width - len);
    while (n) put(buf[--n]);
    if (left) put_pad(' ', width - len);
}

int uvprintf(const char* fmt, va_list ap) {
    out_cnt = 0;
    for (; *fmt; fmt++) {
        if (*fmt != '%') { if (*fmt == '\n') put('\r'); put(*fmt); continue; }
        fmt++;
        int left = 0, width = 0; char pad = ' ';
        if (*fmt == '-') { left = 1; fmt++; }
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') fmt++;                  // RV32: long == int
        switch (*fmt) {
        case 'd': case 'i': {
            int32_t v = va_arg(ap, int32_t);
            put_num(v < 0 ? (uint32_t)(-v) : (uint32_t)v, 10, 0, v < 0, width, pad, left);
            break; }
        case 'u': put_num(va_arg(ap, uint32_t), 10, 0, 0, width, pad, left); break;
        case 'x': put_num(va_arg(ap, uint32_t), 16, 0, 0, width, pad, left); break;
        case 'X': put_num(va_arg(ap, uint32_t), 16, 1, 0, width, pad, left); break;
        case 'p': put('0'); put('x'); put_num(va_arg(ap, uint32_t), 16, 0, 0, 8, '0', 0); break;
        case 'c': put((char)va_arg(ap, int)); break;
        case 's': {
            const char* s = va_arg(ap, const char*);
            int len = 0; while (s[len]) len++;
            if (!left) put_pad(' ', width - len);
            while (*s) put(*s++);
            if (left) put_pad(' ', width - len);
            break; }
        case '%': put('%'); break;
        case '\0': return out_cnt;
        default:  put('%'); put(*fmt); break;
        }
    }
    return out_cnt;
}

int uprintf(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int n = uvprintf(fmt, ap);
    va_end(ap);
    return n;
}
