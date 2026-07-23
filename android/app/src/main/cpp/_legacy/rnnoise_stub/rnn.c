/* Copyright (c) 2008-2011 Octasic Inc.
   Copyright (c) 2017 Mozilla
   Written by Jean-Marc Valin
   
   Minimal stub for RNN computation used by RNNoise.
   Replace with the full rnn.c from the RNNoise repository.
*/

#include "rnn.h"
#include "tansig_table.h"
#include "freq.h"
#include <math.h>
#include <string.h>

/* Tansig approximation (fast tanh) */
static inline float tansig_approx(float x) {
    if (x >= 8.0f) return 1.0f;
    if (x <= -8.0f) return -1.0f;
    /* Use lookup table */
    float sign = 1.0f;
    if (x < 0) {
        x = -x;
        sign = -1.0f;
    }
    int i = (int)(0.5f + 25.0f * x);
    if (i > 200) i = 200;
    float y = tansig_table[i];
    return sign * y;
}

/* Sigmoid approximation */
static inline float sigmoid_approx(float x) {
    return 0.5f + 0.5f * tansig_approx(0.5f * x);
}

/* ReLU activation */
static inline float relu(float x) {
    return x > 0.0f ? x : 0.0f;
}

void compute_dense(const DenseLayer *layer, float *output, const float *input) {
    int i, j;
    int N = layer->nb_neurons;
    int M = layer->nb_inputs;
    
    for (i = 0; i < N; i++) {
        float sum = layer->bias[i];
        for (j = 0; j < M; j++) {
            sum += layer->input_weights[i * M + j] * input[j];
        }
        /* Apply activation */
        switch (layer->activation) {
            case ACTIVATION_SIGMOID:
                output[i] = sigmoid_approx(sum);
                break;
            case ACTIVATION_TANH:
                output[i] = tansig_approx(sum);
                break;
            case ACTIVATION_RELU:
                output[i] = relu(sum);
                break;
            default:
                output[i] = sum;
                break;
        }
    }
}

void compute_gru(const GRULayer *layer, float *state, const float *input) {
    int i, j;
    int N = layer->nb_neurons;
    int M = layer->nb_inputs;
    float z[96]; /* max GRU size */
    float r[96];
    float h[96];
    
    /* Compute update gate z */
    for (i = 0; i < N; i++) {
        float sum = layer->bias[i];
        for (j = 0; j < M; j++) {
            sum += layer->input_weights[i * M + j] * input[j];
        }
        for (j = 0; j < N; j++) {
            sum += layer->recurrent_weights[i * N + j] * state[j];
        }
        z[i] = sigmoid_approx(sum);
    }
    
    /* Compute reset gate r */
    for (i = 0; i < N; i++) {
        float sum = layer->bias[N + i];
        for (j = 0; j < M; j++) {
            sum += layer->input_weights[(N + i) * M + j] * input[j];
        }
        for (j = 0; j < N; j++) {
            sum += layer->recurrent_weights[(N + i) * N + j] * state[j];
        }
        r[i] = sigmoid_approx(sum);
    }
    
    /* Compute candidate h */
    for (i = 0; i < N; i++) {
        float sum = layer->bias[2 * N + i];
        for (j = 0; j < M; j++) {
            sum += layer->input_weights[(2 * N + i) * M + j] * input[j];
        }
        for (j = 0; j < N; j++) {
            sum += layer->recurrent_weights[(2 * N + i) * N + j] * state[j] * r[j];
        }
        /* Apply activation to candidate */
        switch (layer->activation) {
            case ACTIVATION_SIGMOID:
                h[i] = sigmoid_approx(sum);
                break;
            case ACTIVATION_TANH:
                h[i] = tansig_approx(sum);
                break;
            case ACTIVATION_RELU:
                h[i] = relu(sum);
                break;
            default:
                h[i] = sum;
                break;
        }
    }
    
    /* Update state: state = z * state + (1-z) * h */
    for (i = 0; i < N; i++) {
        state[i] = z[i] * state[i] + (1.0f - z[i]) * h[i];
    }
}

void compute_rnn(RNNState *rnn, float *gains, float *vad, const float *input) {
    /* Stub implementation: output unity gains (pass-through) and zero VAD.
       When real trained weights are loaded, this function will compute
       the full RNN inference through input_dense → vad_gru → noise_gru →
       denoise_gru → denoise_output layers. */
    (void)rnn;
    (void)input;
    
    for (int i = 0; i < NB_BANDS; i++) {
        gains[i] = 1.0f; /* Pass-through when using stub weights */
    }
    *vad = 0.0f;
}
