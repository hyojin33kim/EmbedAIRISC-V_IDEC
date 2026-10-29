// UART 정수 출력 함수의 인터페이스를 선언한다.
#ifndef UPRINTF_H_
#define UPRINTF_H_

#include <stdarg.h>

int uprintf(const char* fmt, ...);
int uvprintf(const char* fmt, va_list ap);

#endif
