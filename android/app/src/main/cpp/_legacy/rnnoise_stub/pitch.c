/* Copyright (c) 2007-2008 CSIRO
   Copyright (c) 2007-2009 Xiph.Org Foundation
   Written by Jean-Marc Valin
   
   Minimal stub for pitch analysis used by RNNoise.
   Replace with the full pitch.c from the RNNoise repository.
*/

#include "pitch.h"
#include "common.h"
#include <string.h>
#include <math.h>

void pitch_downsample(float *x[], float *x_lp, int len, int C) {
    int i;
    float ac[5] = {0};
    float lpc[4], mem[5] = {0};
    float lpc2[5];
    float tmp = 1.0f;
    
    for (i = 1; i < len >> 1; i++) {
        x_lp[i] = 0.5f * (0.5f * (x[0][(2*i-1)] + x[0][(2*i+1)]) + x[0][2*i]);
    }
    x_lp[0] = 0.5f * (0.5f * x[0][1] + x[0][0]);
    
    if (C == 2) {
        for (i = 1; i < len >> 1; i++) {
            x_lp[i] += 0.5f * (0.5f * (x[1][(2*i-1)] + x[1][(2*i+1)]) + x[1][2*i]);
        }
        x_lp[0] += 0.5f * (0.5f * x[1][1] + x[1][0]);
    }
    
    /* Simple autocorrelation */
    for (i = 0; i < 5; i++) {
        int j;
        ac[i] = 0;
        for (j = i; j < (len >> 1); j++) {
            ac[i] += x_lp[j] * x_lp[j - i];
        }
    }
    
    /* Levinson-Durbin */
    _celt_lpc(lpc, ac, 4);
    
    /* Apply pre-emphasis filter */
    (void)lpc2;
    (void)mem;
    (void)tmp;
}

void pitch_search(const float *x_lp, float *y, int len, int max_pitch, int *pitch) {
    int i, j;
    int best_pitch = 0;
    float best_corr = -1e15f;
    int lag = len;
    
    (void)y;
    
    for (i = 0; i < max_pitch; i++) {
        float corr = 0.0f;
        float energy = 0.0f;
        for (j = 0; j < lag && (j + i) < len; j++) {
            corr += x_lp[j] * x_lp[j + i];
            energy += x_lp[j + i] * x_lp[j + i];
        }
        if (energy > 1e-10f) {
            corr /= sqrtf(energy);
        }
        if (corr > best_corr) {
            best_corr = corr;
            best_pitch = i;
        }
    }
    
    *pitch = best_pitch;
}

float remove_doubling(float *x, int maxperiod, int minperiod, int N,
                      int *T0, int prev_period, float prev_gain) {
    int best_period = *T0;
    float best_gain = 0.0f;
    int i;
    
    (void)maxperiod;
    (void)minperiod;
    (void)prev_period;
    (void)prev_gain;
    
    /* Simple pitch refinement */
    float energy = 0.0f;
    float corr = 0.0f;
    for (i = 0; i < N; i++) {
        energy += x[i] * x[i];
    }
    
    if (best_period > 0 && best_period < N) {
        for (i = 0; i < N - best_period; i++) {
            corr += x[i] * x[i + best_period];
        }
        if (energy > 1e-10f) {
            best_gain = corr / energy;
        }
    }
    
    *T0 = best_period;
    return best_gain;
}
