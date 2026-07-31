/* Copyright (c) 2017 Mozilla */
/**
   @file freq.h
   @brief Frequency-domain definitions for RNNoise
*/
#ifndef FREQ_H
#define FREQ_H

#define FREQ_SIZE 481
#define WINDOW_SIZE 480
#define FRAME_SIZE 480

#define NB_BANDS 22
#define CEPS_MEM 8
#define NB_DELTA_CEPS 6
#define NB_FEATURES (NB_BANDS + 3*NB_DELTA_CEPS + 2)

#endif /* FREQ_H */
