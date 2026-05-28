/* Copyright (c) 2003-2004, Mark Borgerding */
/**
   @file kiss_fft.h
   @brief KISS FFT header for RNNoise
*/
#ifndef KISS_FFT_H
#define KISS_FFT_H

#include <stdlib.h>
#include <math.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define kiss_fft_scalar float

typedef struct {
    kiss_fft_scalar r;
    kiss_fft_scalar i;
} kiss_fft_cpx;

#define KISS_FFT_MALLOC(nbytes) malloc(nbytes)
#define KISS_FFT_FREE(ptr) free(ptr)

#define MAXFACTORS 32

struct kiss_fft_state {
    int nfft;
    int inverse;
    int factors[2*MAXFACTORS];
    kiss_fft_cpx twiddles[1]; /* flexible array member */
};

typedef struct kiss_fft_state* kiss_fft_cfg;

kiss_fft_cfg kiss_fft_alloc(int nfft, int inverse_fft, void* mem, size_t* lenmem);
void kiss_fft(kiss_fft_cfg cfg, const kiss_fft_cpx* fin, kiss_fft_cpx* fout);
void kiss_fft_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* KISS_FFT_H */
