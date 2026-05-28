/* Copyright (c) 2017 Mozilla */
/**
   @file common.h
   @brief Common definitions for RNNoise
*/
#ifndef COMMON_H
#define COMMON_H

#define RNN_MOVE(dst, src, n) (memmove((dst), (src), (n)*sizeof(*(dst))))
#define RNN_CLEAR(dst, n) (memset((dst), 0, (n)*sizeof(*(dst))))
#define RNN_COPY(dst, src, n) (memcpy((dst), (src), (n)*sizeof(*(dst))))

#endif /* COMMON_H */
