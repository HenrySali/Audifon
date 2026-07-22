/* Copyright (c) 2009-2010 Xiph.Org Foundation
   Written by Jean-Marc Valin */
/**
   @file celt_lpc.h
   @brief Linear prediction functions from CELT
*/
#ifndef CELT_LPC_H
#define CELT_LPC_H

#include "arch.h"

#ifdef __cplusplus
extern "C" {
#endif

void _celt_lpc(float *_lpc, const float *ac, int p);
void celt_fir(const float *x, const float *num, float *y, int N, int ord, float *mem);
void celt_iir(const float *x, const float *den, float *y, int N, int ord, float *mem);

#ifdef __cplusplus
}
#endif

#endif /* CELT_LPC_H */
