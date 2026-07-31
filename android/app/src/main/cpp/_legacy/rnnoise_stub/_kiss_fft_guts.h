/* Copyright (c) 2003-2004, Mark Borgerding */
/**
   @file _kiss_fft_guts.h
   @brief Internal KISS FFT definitions
*/
#ifndef _KISS_FFT_GUTS_H
#define _KISS_FFT_GUTS_H

#include "kiss_fft.h"

/* Macros for complex arithmetic */
#define C_ADD(res, a, b) \
    do { (res).r = (a).r + (b).r; (res).i = (a).i + (b).i; } while(0)

#define C_SUB(res, a, b) \
    do { (res).r = (a).r - (b).r; (res).i = (a).i - (b).i; } while(0)

#define C_ADDTO(res, a) \
    do { (res).r += (a).r; (res).i += (a).i; } while(0)

#define C_SUBFROM(res, a) \
    do { (res).r -= (a).r; (res).i -= (a).i; } while(0)

#define C_MUL(m, a, b) \
    do { (m).r = (a).r*(b).r - (a).i*(b).i; \
         (m).i = (a).r*(b).i + (a).i*(b).r; } while(0)

#define C_MULBYSCALAR(c, s) \
    do { (c).r *= (s); (c).i *= (s); } while(0)

#define CHECK_OVERFLOW_OP(a, op, b) /* noop */

#define C_FIXDIV(c, div) /* noop for float */

#define S_MUL(a, b) ((a)*(b))

#ifndef TWO_PI
#define TWO_PI 6.2831853071795864769252867665590057683943f
#endif

#define kf_cexp(x, phase) \
    do { (x)->r = cosf(phase); (x)->i = sinf(phase); } while(0)

#endif /* _KISS_FFT_GUTS_H */
