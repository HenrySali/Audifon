/* Copyright (c) 2017 Mozilla */
/**
   @file pitch.h
   @brief Pitch analysis for RNNoise
*/
#ifndef PITCH_H
#define PITCH_H

#include "arch.h"
#include "kiss_fft.h"

#ifdef __cplusplus
extern "C" {
#endif

void pitch_downsample(float *x[], float *x_lp, int len, int C);
void pitch_search(const float *x_lp, float *y, int len, int max_pitch, int *pitch);
float remove_doubling(float *x, int maxperiod, int minperiod, int N,
                      int *T0, int prev_period, float prev_gain);

#ifdef __cplusplus
}
#endif

#endif /* PITCH_H */
