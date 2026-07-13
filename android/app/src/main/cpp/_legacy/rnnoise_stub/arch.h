/* Copyright (c) 2003-2008 Jean-Marc Valin
   Copyright (c) 2007-2008 CSIRO
   Copyright (c) 2007-2009 Xiph.Org Foundation
   Written by Jean-Marc Valin */
/**
   @file arch.h
   @brief Various architecture definitions for RNNoise
*/
#ifndef ARCH_H
#define ARCH_H

#include "opus_types.h"

#include <math.h>
#include <string.h>
#include <stdlib.h>

typedef float rnn_weight;

#define OPUS_INLINE inline

#define celt_fatal(str) abort()

#define IMUL32(a,b) ((a)*(b))

#define MIN16(a,b) ((a) < (b) ? (a) : (b))
#define MAX16(a,b) ((a) > (b) ? (a) : (b))
#define MIN32(a,b) ((a) < (b) ? (a) : (b))
#define MAX32(a,b) ((a) > (b) ? (a) : (b))
#define IMIN(a,b) ((a) < (b) ? (a) : (b))
#define IMAX(a,b) ((a) > (b) ? (a) : (b))

#define Q15ONE 1.0f

#define FLOAT_DMUL(a,b) ((a)*(b))

#define MULT16_16(a,b)     ((float)(a)*(float)(b))
#define MULT16_32_Q15(a,b) ((float)(a)*(float)(b))

#define SHR32(a,shift) (a)
#define SHL32(a,shift) (a)
#define PSHR32(a,shift) (a)

#define SATURATE(x,a) (x)
#define SATURATE16(x) (x)

#define EXTEND32(x) (x)
#define HALF32(x) (.5f*(x))

#define ADD32(a,b) ((a)+(b))
#define SUB32(a,b) ((a)-(b))

#define VSHR32(a,shift) (a)

#define QCONST16(x,bits) (x)
#define QCONST32(x,bits) (x)

#define NEG16(x) (-(x))
#define NEG32(x) (-(x))

#define EXTRACT16(x) (x)

#define SHR(a,shift) (a)
#define SHL(a,shift) (a)

#define ABS16(x) ((float)fabs(x))
#define ABS32(x) ((float)fabs(x))

static OPUS_INLINE float SQRT(float x) { return sqrtf(x); }

#endif /* ARCH_H */
