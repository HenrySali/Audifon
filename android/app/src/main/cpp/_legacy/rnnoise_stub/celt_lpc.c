/* Copyright (c) 2009-2010 Xiph.Org Foundation
   Written by Jean-Marc Valin
   
   Minimal stub for CELT LPC functions used by RNNoise.
   Replace with the full celt_lpc.c from the RNNoise repository.
*/

#include "celt_lpc.h"
#include <string.h>

void _celt_lpc(float *_lpc, const float *ac, int p) {
    int i, j;
    float r;
    float error = ac[0];
    float lpc[24]; /* max order */
    
    memset(lpc, 0, sizeof(float) * (size_t)p);
    
    if (error <= 0) {
        memset(_lpc, 0, sizeof(float) * (size_t)p);
        return;
    }
    
    for (i = 0; i < p; i++) {
        /* Sum up this iteration's reflection coefficient */
        float rr = 0;
        for (j = 0; j < i; j++)
            rr += lpc[j] * ac[i - j];
        rr += ac[i + 1];
        r = -rr / error;
        
        /* Update LPC coefficients and total error */
        lpc[i] = r;
        for (j = 0; j < (i + 1) >> 1; j++) {
            float tmp1, tmp2;
            tmp1 = lpc[j];
            tmp2 = lpc[i - 1 - j];
            lpc[j] = tmp1 + r * tmp2;
            lpc[i - 1 - j] = tmp2 + r * tmp1;
        }
        
        error = error - error * r * r;
        if (error < 0.001f * ac[0]) {
            memset(_lpc, 0, sizeof(float) * (size_t)p);
            return;
        }
    }
    
    for (i = 0; i < p; i++)
        _lpc[i] = lpc[i];
}

void celt_fir(const float *x, const float *num, float *y, int N, int ord, float *mem) {
    int i, j;
    for (i = 0; i < N; i++) {
        float sum = x[i];
        for (j = 0; j < ord; j++) {
            sum += num[j] * mem[j];
        }
        /* Shift memory */
        for (j = ord - 1; j > 0; j--) {
            mem[j] = mem[j - 1];
        }
        mem[0] = x[i];
        y[i] = sum;
    }
}

void celt_iir(const float *x, const float *den, float *y, int N, int ord, float *mem) {
    int i, j;
    for (i = 0; i < N; i++) {
        float sum = x[i];
        for (j = 0; j < ord; j++) {
            sum -= den[j] * mem[j];
        }
        /* Shift memory */
        for (j = ord - 1; j > 0; j--) {
            mem[j] = mem[j - 1];
        }
        mem[0] = sum;
        y[i] = sum;
    }
}
