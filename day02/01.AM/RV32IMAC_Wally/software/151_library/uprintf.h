#ifndef UPRINTF_H_
#define UPRINTF_H_

#include <stdarg.h>

int uprintf(const char* fmt, ...);
int uvprintf(const char* fmt, va_list ap);

#endif
