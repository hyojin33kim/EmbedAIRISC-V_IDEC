// 펌웨어의 부동소수점 타입 사용을 컴파일 단계에서 차단한다.
/* Force-include in EVERY firmware C translation unit, including model.c.
 * GCC/Clang reject active floating-point type tokens; verify_firmware.py also
 * rejects floating literals and audits the linked ELF for software FP helpers.
 * Host-only wrappers/metadata are excluded before these tokens are processed. */
#ifndef INT8_C_FIRMWARE_NO_FLOAT_H
#define INT8_C_FIRMWARE_NO_FLOAT_H
#ifndef MODEL_INTEGER_ONLY
#error "Firmware requires -DMODEL_INTEGER_ONLY in every translation unit"
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC poison float double __fp16 __bf16 __float80 __float128 _Float16 _Float32 _Float32x _Float64 _Float64x _Float128 _Float128x _Decimal32 _Decimal64 _Decimal128
#else
#error "Use a compiler supporting GCC poison for the no-FP firmware build"
#endif
#endif
