#include "util.h"

#include <stdarg.h>
#include <string.h>
#include "uprintf.h"

void debug_printf(const char* fmt, ...) {
	va_list args;
	va_start(args, fmt);
	uvprintf(fmt, args);
	va_end(args);
}

void* memcpy(void* dest, const void* src, size_t len) {
	char* d = dest; const char* s = src;
	while (len--) *d++ = *s++;
	return dest;
}

void* memset(void* dest, int byte, size_t len) {
	char* d = dest;
	while (len--) *d++ = (char)byte;
	return dest;
}

char* strcpy(char* dest, const char* src) {
	char* d = dest;
	while ((*d++ = *src++))
		;
	return dest;
}

int strcmp(const char* s1, const char* s2) {
	unsigned char c1, c2;
	do {
		c1 = *s1++;
		c2 = *s2++;
	} while (c1 != 0 && c1 == c2);
	return c1 - c2;
}
