/* Copyright (c) 2003-2004, Mark Borgerding
   All rights reserved.
   
   Minimal stub implementation of KISS FFT for RNNoise compilation.
   Replace with the full kiss_fft.c from the RNNoise repository for
   actual functionality.
*/

#include "kiss_fft.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

kiss_fft_cfg kiss_fft_alloc(int nfft, int inverse_fft, void* mem, size_t* lenmem) {
    size_t memneeded = sizeof(struct kiss_fft_state) + sizeof(kiss_fft_cpx) * (size_t)(nfft - 1);
    
    if (lenmem == NULL) {
        kiss_fft_cfg st = (kiss_fft_cfg)KISS_FFT_MALLOC(memneeded);
        if (st == NULL) return NULL;
        st->nfft = nfft;
        st->inverse = inverse_fft;
        /* Compute twiddle factors */
        for (int i = 0; i < nfft; ++i) {
            double phase = -2.0 * M_PI * i / nfft;
            if (inverse_fft) phase = -phase;
            st->twiddles[i].r = (float)cos(phase);
            st->twiddles[i].i = (float)sin(phase);
        }
        /* Simple factorization */
        int n = nfft;
        int p = 0;
        int f = 4;
        while (n > 1) {
            while (n % f) {
                switch (f) {
                    case 4: f = 2; break;
                    case 2: f = 3; break;
                    default: f += 2; break;
                }
                if (f * f > n) { f = n; break; }
            }
            n /= f;
            st->factors[2*p] = f;
            st->factors[2*p+1] = n;
            ++p;
        }
        return st;
    }
    
    if (mem != NULL && *lenmem >= memneeded) {
        kiss_fft_cfg st = (kiss_fft_cfg)mem;
        st->nfft = nfft;
        st->inverse = inverse_fft;
        for (int i = 0; i < nfft; ++i) {
            double phase = -2.0 * M_PI * i / nfft;
            if (inverse_fft) phase = -phase;
            st->twiddles[i].r = (float)cos(phase);
            st->twiddles[i].i = (float)sin(phase);
        }
        return st;
    }
    
    *lenmem = memneeded;
    return NULL;
}

/* Naive DFT — O(N^2). Replace with full KISS FFT for production. */
void kiss_fft(kiss_fft_cfg cfg, const kiss_fft_cpx* fin, kiss_fft_cpx* fout) {
    int N = cfg->nfft;
    float scale = cfg->inverse ? 1.0f / (float)N : 1.0f;
    
    for (int k = 0; k < N; k++) {
        fout[k].r = 0.0f;
        fout[k].i = 0.0f;
        for (int n = 0; n < N; n++) {
            int twidx = (int)(((long)k * n) % N);
            kiss_fft_cpx tw = cfg->twiddles[twidx];
            fout[k].r += fin[n].r * tw.r - fin[n].i * tw.i;
            fout[k].i += fin[n].r * tw.i + fin[n].i * tw.r;
        }
        fout[k].r *= scale;
        fout[k].i *= scale;
    }
}

void kiss_fft_cleanup(void) {
    /* Nothing to do */
}
