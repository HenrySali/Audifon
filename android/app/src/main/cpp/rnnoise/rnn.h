/* Copyright (c) 2017 Mozilla */
/**
   @file rnn.h
   @brief RNN layer definitions for RNNoise
*/
#ifndef RNN_H
#define RNN_H

#include "opus_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ACTIVATION_TANH    0
#define ACTIVATION_SIGMOID 1
#define ACTIVATION_RELU    2

typedef struct {
    const float *bias;
    const float *input_weights;
    int nb_inputs;
    int nb_neurons;
    int activation;
} DenseLayer;

typedef struct {
    const float *bias;
    const float *input_weights;
    const float *recurrent_weights;
    int nb_inputs;
    int nb_neurons;
    int activation;
} GRULayer;

typedef struct {
    int model_loaded;
    /* Layers */
    DenseLayer input_dense;
    GRULayer vad_gru;
    GRULayer noise_gru;
    GRULayer denoise_gru;
    DenseLayer denoise_output;
    DenseLayer vad_output;
} RNNModel;

typedef struct {
    float vad_gru_state[24];
    float noise_gru_state[48];
    float denoise_gru_state[96];
} RNNState;

void compute_dense(const DenseLayer *layer, float *output, const float *input);
void compute_gru(const GRULayer *layer, float *state, const float *input);
void compute_rnn(RNNState *rnn, float *gains, float *vad, const float *input);

#ifdef __cplusplus
}
#endif

#endif /* RNN_H */
