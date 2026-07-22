/**
 * =============================================================================
 * DSP Engine — Browser-Compatible Version
 * 
 * This is a browser-compatible copy of dsp-engine.js.
 * Instead of module.exports, everything is exposed via window.DspEngine.
 * DO NOT modify dsp-engine.js — that file is for Node.js/tests.
 * =============================================================================
 */

(function() {
'use strict';

// --- Pipeline Constants (identical to firmware dsp_types.h) ---

const BLOCK_SIZE = 64;
const SAMPLE_RATE = 16000;
const NUM_BANDS = 12;
const AFC_TAPS = 64;
const NR_SUB_BANDS = 8;
const EQ_Q_FACTOR = 2.0;
const BIQUADS_PER_BAND = 2;
const MPO_ATTACK_MS = 0.5;
const MPO_RELEASE_MS = 10.0;
const MPO_DBFS_TO_SPL_OFFSET = 120.0;

// --- AFC (Feedback Canceller) Constants ---

const AFC_MU_DEFAULT = 0.005;
const AFC_MU_MIN = 0.001;
const AFC_MU_MAX = 0.01;
const AFC_POWER_FLOOR = 1e-10;

// --- Noise Reducer Constants ---

const NR_GAIN_SMOOTH_FACTOR = 0.85;
const NR_ALPHA_NOISE = 0.98;
const NR_ALPHA_SIGNAL = 0.8;
const NR_ADAPTATION_BLOCKS = 125;
const NR_EPSILON = 1e-10;
const NR_SPEECH_THRESHOLD = 2.0;
const NR_ALPHA_P = 0.2;

// --- WDRC Constants ---

const WDRC_ENVELOPE_FLOOR_DB = 0.0;
const WDRC_EXPANSION_KNEE_DEFAULT = 35.0;  // dB SPL — expansion kneepoint
const WDRC_EXPANSION_RATIO_DEFAULT = 2.0;  // input:output expansion ratio

// WDRC Calibration Offset: converts dBFS to "input SPL" for WDRC decisions.
// In a real hearing aid, 0 dBFS from the mic ADC corresponds to ~94 dB SPL.
// For the web simulator processing WAV files, we use a calibration where:
//   -26 dBFS (typical WAV speech level) ≈ 50 dB SPL (soft conversation)
// This means: SPL = dBFS + 76
// This ensures the WDRC kneepoint (typically 45-65 dB SPL) activates at
// appropriate digital levels, preserving net positive amplification.
const WDRC_DBFS_TO_SPL_OFFSET = 76.0;

// --- EQ Center Frequencies (Hz) ---

const EQ_CENTER_FREQUENCIES = [
    250, 500, 750, 1000, 1500, 2000,
    2500, 3000, 3500, 4000, 6000, 8000
];

// --- Noise Reducer Gain Floors by Level ---

const NR_GAIN_FLOORS = [1.0, 0.56, 0.32, 0.18];

// --- Noise Reducer Over-Subtraction Factors by Level ---

const NR_OVERSUBTRACTION = [1.0, 1.5, 2.0, 3.0];

// --- Noise Reducer Sub-Band Boundaries (sample indices) ---

const NR_SUBBAND_BOUNDARIES = [0, 8, 16, 24, 32, 40, 48, 56, 64];

// --- Validation Ranges (from config_types.h) ---

const VALIDATION = {
    EQ_GAIN: { min: 0, max: 50 },
    AGC_RATIO: { min: 10, max: 40 },
    AGC_KNEEPOINT: { min: 40, max: 80 },
    AGC_ATTACK: { min: 1, max: 10 },
    AGC_RELEASE: { min: 50, max: 500 },
    MPO_THRESHOLD: { min: 90, max: 110 },
    NR_LEVEL: { min: 0, max: 3 },
    VOLUME: { min: -20, max: 10 },
    FEEDBACK: { min: 0, max: 1 }
};

// =============================================================================
// BiquadFilter — Direct Form II Transposed
// =============================================================================

class BiquadFilter {
    constructor() {
        this.b0 = 1.0;
        this.b1 = 0.0;
        this.b2 = 0.0;
        this.a1 = 0.0;
        this.a2 = 0.0;
        this.z1 = 0.0;
        this.z2 = 0.0;
    }

    process(x) {
        const y = this.b0 * x + this.z1;
        this.z1 = this.b1 * x - this.a1 * y + this.z2;
        this.z2 = this.b2 * x - this.a2 * y;
        return y;
    }

    reset() {
        this.z1 = 0.0;
        this.z2 = 0.0;
    }
}

// =============================================================================
// Conversion Utilities
// =============================================================================

function convertInt16ToFloat(input) {
    const output = new Float32Array(BLOCK_SIZE);
    for (let i = 0; i < BLOCK_SIZE; i++) {
        output[i] = input[i] / 32768.0;
    }
    return output;
}

function convertFloatToInt16(input) {
    const output = new Int16Array(BLOCK_SIZE);
    for (let i = 0; i < BLOCK_SIZE; i++) {
        let sample = input[i] * 32767.0;
        if (sample > 32767.0) sample = 32767.0;
        else if (sample < -32768.0) sample = -32768.0;
        output[i] = Math.round(sample);
    }
    return output;
}

function calculateTimeCoefficient(timeMs) {
    const samples = timeMs * SAMPLE_RATE / 1000.0;
    return 1.0 - Math.exp(-1.0 / Math.max(samples, 1.0));
}

function dbToLinear(db) {
    return Math.pow(10.0, db / 20.0);
}

// =============================================================================
// Equalizer — 12-Band Peaking EQ
// =============================================================================

function computeBiquadCoeffs(filter, fc, gainDb, q, fs) {
    if (gainDb <= 0.0) {
        filter.b0 = 1.0; filter.b1 = 0.0; filter.b2 = 0.0;
        filter.a1 = 0.0; filter.a2 = 0.0;
        return;
    }

    // For frequencies above 0.4 × Nyquist, use high-shelf instead of peaking
    const nyquist = fs / 2;
    if (fc > nyquist * 0.85) {
        // High-shelf centered at 0.25 × Nyquist (2000 Hz at 16kHz SR)
        // Low cutoff + gentle slope ensures full gain delivery by 6-7 kHz
        const shelfFc = nyquist * 0.25;
        const A = Math.pow(10.0, gainDb / 40.0);
        const w0 = 2.0 * Math.PI * shelfFc / fs;
        const sinW0 = Math.sin(w0);
        const cosW0 = Math.cos(w0);
        // Shelf slope S=0.4 — very gradual transition reaching full gain well below Nyquist
        const S = 0.4;
        const alpha = sinW0 / 2.0 * Math.sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);

        const b0 = A * ((A + 1) + (A - 1) * cosW0 + 2 * Math.sqrt(A) * alpha);
        const b1 = -2 * A * ((A - 1) + (A + 1) * cosW0);
        const b2 = A * ((A + 1) + (A - 1) * cosW0 - 2 * Math.sqrt(A) * alpha);
        const a0 = (A + 1) - (A - 1) * cosW0 + 2 * Math.sqrt(A) * alpha;
        const a1 = 2 * ((A - 1) - (A + 1) * cosW0);
        const a2 = (A + 1) - (A - 1) * cosW0 - 2 * Math.sqrt(A) * alpha;

        const invA0 = 1.0 / a0;
        filter.b0 = b0 * invA0;
        filter.b1 = b1 * invA0;
        filter.b2 = b2 * invA0;
        filter.a1 = a1 * invA0;
        filter.a2 = a2 * invA0;
        return;
    }

    const A = Math.pow(10.0, gainDb / 40.0);
    const w0 = 2.0 * Math.PI * fc / fs;
    const sinW0 = Math.sin(w0);
    const cosW0 = Math.cos(w0);
    const alpha = sinW0 / (2.0 * q);

    const b0 = 1.0 + alpha * A;
    const b1 = -2.0 * cosW0;
    const b2 = 1.0 - alpha * A;
    const a0 = 1.0 + alpha / A;
    const a1 = -2.0 * cosW0;
    const a2 = 1.0 - alpha / A;

    const invA0 = 1.0 / a0;
    filter.b0 = b0 * invA0;
    filter.b1 = b1 * invA0;
    filter.b2 = b2 * invA0;
    filter.a1 = a1 * invA0;
    filter.a2 = a2 * invA0;
}

function computeAdaptiveQ(gainDb, baseQ) {
    if (gainDb <= 3.0) return baseQ;
    const qBoost = 1.0 + (gainDb - 3.0) / 12.0;
    return Math.min(baseQ * qBoost, 6.0);
}

function computeOverlapCompensation(band, gains, frequencies) {
    let overlapDb = 0;
    const fc = frequencies[band];
    for (let adj = 0; adj < NUM_BANDS; adj++) {
        if (adj === band || gains[adj] <= 0) continue;
        const octaveDistance = Math.abs(Math.log2(fc / frequencies[adj]));
        const adjQ = computeAdaptiveQ(gains[adj], EQ_Q_FACTOR);
        const rolloff = 20 * Math.log10(1.0 / (1.0 + Math.pow(2 * adjQ * octaveDistance, 2)));
        const contribution = gains[adj] + rolloff;
        if (contribution > 0) overlapDb += contribution;
    }
    return overlapDb;
}

function createEqualizer() {
    const filters = [];
    const gainsDb = new Float32Array(NUM_BANDS);

    for (let band = 0; band < NUM_BANDS; band++) {
        filters[band] = [];
        for (let bq = 0; bq < BIQUADS_PER_BAND; bq++) {
            filters[band][bq] = new BiquadFilter();
        }
    }

    return {
        filters,
        gainsDb,

        init() {
            for (let band = 0; band < NUM_BANDS; band++) {
                gainsDb[band] = 0;
                for (let bq = 0; bq < BIQUADS_PER_BAND; bq++) {
                    filters[band][bq] = new BiquadFilter();
                }
            }
        },

        setBandGain(band, gainDb) {
            if (band < 0 || band >= NUM_BANDS) return;
            gainDb = Math.max(0, Math.min(gainDb, 50));
            gainsDb[band] = gainDb;

            const adaptiveQ = computeAdaptiveQ(gainDb, EQ_Q_FACTOR);
            computeBiquadCoeffs(
                filters[band][0],
                EQ_CENTER_FREQUENCIES[band],
                gainDb,
                adaptiveQ,
                SAMPLE_RATE
            );
            filters[band][1].b0 = 1.0;
            filters[band][1].b1 = 0.0;
            filters[band][1].b2 = 0.0;
            filters[band][1].a1 = 0.0;
            filters[band][1].a2 = 0.0;
        },

        setAllGains(gains) {
            for (let band = 0; band < NUM_BANDS; band++) {
                gainsDb[band] = Math.max(0, Math.min(gains[band] || 0, 50));
            }
            for (let band = 0; band < NUM_BANDS; band++) {
                const rawGain = gainsDb[band];
                if (rawGain <= 0) {
                    filters[band][0].b0 = 1.0; filters[band][0].b1 = 0.0; filters[band][0].b2 = 0.0;
                    filters[band][0].a1 = 0.0; filters[band][0].a2 = 0.0;
                    filters[band][1].b0 = 1.0; filters[band][1].b1 = 0.0; filters[band][1].b2 = 0.0;
                    filters[band][1].a1 = 0.0; filters[band][1].a2 = 0.0;
                    continue;
                }
                // Overlap compensation — skip for high-shelf band (last band)
                // High-shelf doesn't produce narrow peaks, so overlap model doesn't apply
                let effectiveGain = rawGain;
                const fc = EQ_CENTER_FREQUENCIES[band];
                if (fc <= (SAMPLE_RATE / 2) * 0.85) {
                    let adjacentCount = 0;
                    let adjacentGainSum = 0;
                    for (let adj = 0; adj < NUM_BANDS; adj++) {
                        if (adj === band || gainsDb[adj] <= 0) continue;
                        const octDist = Math.abs(Math.log2(fc / EQ_CENTER_FREQUENCIES[adj]));
                        if (octDist < 1.2) {
                            adjacentCount++;
                            // High-shelf bands contribute full gain (no rolloff above fc)
                            const isShelf = EQ_CENTER_FREQUENCIES[adj] > (SAMPLE_RATE / 2) * 0.85;
                            const weight = isShelf ? 0.9 : Math.pow(1.0 - octDist / 1.2, 2);
                            adjacentGainSum += gainsDb[adj] * weight;
                        }
                    }
                    // Adaptive overlap factor: scales down for high-gain presets
                    // At 10 dB avg gain → factor ~0.40 (strong compensation)
                    // At 30 dB avg gain → factor ~0.13 (light compensation)
                    const avgGain = gainsDb.reduce((s, g) => s + g, 0) / NUM_BANDS;
                    const overlapFactor = Math.max(0.08, 0.55 - avgGain * 0.014);
                    const overlapReduction = adjacentCount > 0 ? adjacentGainSum * overlapFactor : 0;
                    effectiveGain = Math.max(rawGain * 0.3, rawGain - overlapReduction);
                }
                const adaptiveQ = computeAdaptiveQ(rawGain, EQ_Q_FACTOR);
                computeBiquadCoeffs(
                    filters[band][0],
                    EQ_CENTER_FREQUENCIES[band],
                    effectiveGain,
                    adaptiveQ,
                    SAMPLE_RATE
                );
                filters[band][1].b0 = 1.0; filters[band][1].b1 = 0.0; filters[band][1].b2 = 0.0;
                filters[band][1].a1 = 0.0; filters[band][1].a2 = 0.0;
            }
        },

        processBlock(input, output) {
            for (let i = 0; i < BLOCK_SIZE; i++) {
                output[i] = input[i];
            }
            for (let band = 0; band < NUM_BANDS; band++) {
                if (gainsDb[band] === 0) continue;
                for (let n = 0; n < BLOCK_SIZE; n++) {
                    let sample = output[n];
                    sample = filters[band][0].process(sample);
                    sample = filters[band][1].process(sample);
                    output[n] = sample;
                }
            }
        },

        resetStates() {
            for (let band = 0; band < NUM_BANDS; band++) {
                for (let bq = 0; bq < BIQUADS_PER_BAND; bq++) {
                    filters[band][bq].reset();
                }
            }
        }
    };
}

// =============================================================================
// WDRC — Wide Dynamic Range Compression, Multi-Band
// =============================================================================

function createWdrcBank() {
    const states = [];

    function createWdrcState() {
        return {
            thresholdDb: 50.0,
            ratio: 2.0,
            expansionKneeDb: WDRC_EXPANSION_KNEE_DEFAULT,
            expansionRatio: WDRC_EXPANSION_RATIO_DEFAULT,
            attackCoeff: calculateTimeCoefficient(5),
            releaseCoeff: calculateTimeCoefficient(100),
            envelope: WDRC_ENVELOPE_FLOOR_DB,
            gainDb: 0.0
        };
    }

    for (let i = 0; i < NUM_BANDS; i++) {
        states.push(createWdrcState());
    }

    function processSample(state, inputDb) {
        if (inputDb > state.envelope) {
            state.envelope += state.attackCoeff * (inputDb - state.envelope);
        } else {
            state.envelope += state.releaseCoeff * (inputDb - state.envelope);
        }
        if (state.envelope < WDRC_ENVELOPE_FLOOR_DB) {
            state.envelope = WDRC_ENVELOPE_FLOOR_DB;
        }
        if (state.envelope > state.thresholdDb) {
            const excess = state.envelope - state.thresholdDb;
            state.gainDb = state.thresholdDb + (excess / state.ratio) - state.envelope;
        } else {
            state.gainDb = 0.0;
        }
        return state.gainDb;
    }

    return {
        states,

        init() {
            for (let i = 0; i < NUM_BANDS; i++) {
                states[i] = createWdrcState();
            }
        },

        configureBand(band, params) {
            if (band < 0 || band >= NUM_BANDS) return false;
            const s = states[band];
            s.ratio = params.ratio;
            s.thresholdDb = params.kneepoint;
            s.attackCoeff = calculateTimeCoefficient(params.attack_ms);
            s.releaseCoeff = calculateTimeCoefficient(params.release_ms);
            return true;
        },

        setParams(ratios, kneepoints, attacks, releases) {
            for (let i = 0; i < NUM_BANDS; i++) {
                const r = ratios[i];
                const k = kneepoints[i];
                const a = attacks[i];
                const rel = releases[i];
                if (r < 1.0 || r > 4.0) return false;
                if (k < VALIDATION.AGC_KNEEPOINT.min || k > VALIDATION.AGC_KNEEPOINT.max) return false;
                if (a < VALIDATION.AGC_ATTACK.min || a > VALIDATION.AGC_ATTACK.max) return false;
                if (rel < VALIDATION.AGC_RELEASE.min || rel > VALIDATION.AGC_RELEASE.max) return false;
            }
            for (let i = 0; i < NUM_BANDS; i++) {
                states[i].ratio = ratios[i];
                states[i].thresholdDb = kneepoints[i];
                states[i].attackCoeff = calculateTimeCoefficient(attacks[i]);
                states[i].releaseCoeff = calculateTimeCoefficient(releases[i]);
            }
            return true;
        },

        setExpansionParams(kneeDb, ratio) {
            if (kneeDb < 20 || kneeDb > 50) return false;
            if (ratio < 1.5 || ratio > 3.0) return false;
            for (let i = 0; i < NUM_BANDS; i++) {
                states[i].expansionKneeDb = kneeDb;
                states[i].expansionRatio = ratio;
            }
            return true;
        },

        _mpoThresholdSpl: 110.0,

        setMpoThreshold(thresholdSpl) {
            this._mpoThresholdSpl = thresholdSpl;
        },

        processBlock(buffer) {
            // WDRC Insertion Gain Model:
            // Measures input level, then modulates gain applied to the signal.
            // - Below kneepoint: no gain reduction (full EQ gain preserved)
            // - Above kneepoint: gain reduced proportionally to ratio
            // Result: output is always louder than input (amplification preserved)
            
            // Measure block RMS level using WDRC calibration offset
            let sumSq = 0;
            for (let i = 0; i < BLOCK_SIZE; i++) {
                sumSq += buffer[i] * buffer[i];
            }
            const rms = Math.sqrt(sumSq / BLOCK_SIZE);
            const inputLevelDb = (rms > 1e-10) ?
                20.0 * Math.log10(rms) + WDRC_DBFS_TO_SPL_OFFSET : WDRC_ENVELOPE_FLOOR_DB;
            
            this.processBlockWithLevel(buffer, inputLevelDb);
        },

        processBlockWithLevel(buffer, inputLevelDb) {
            // Use primary state (band 7 = 3kHz, representative of high-frequency hearing loss)
            const state = states[7];
            
            // --- Sample-by-sample peak detection on post-EQ buffer ---
            // Detect transient peaks that block-rate RMS would miss
            let peakPostEqDb = WDRC_ENVELOPE_FLOOR_DB;
            for (let i = 0; i < BLOCK_SIZE; i++) {
                const sampleLevel = Math.abs(buffer[i]);
                const sampleDb = (sampleLevel > 1e-10) ?
                    20.0 * Math.log10(sampleLevel) + WDRC_DBFS_TO_SPL_OFFSET :
                    WDRC_ENVELOPE_FLOOR_DB;
                if (sampleDb > peakPostEqDb) {
                    peakPostEqDb = sampleDb;
                }
            }
            
            // Envelope follower on input level (block-rate update)
            // Convert per-sample coefficients to per-block equivalents
            const blockAttack = 1.0 - Math.pow(1.0 - state.attackCoeff, BLOCK_SIZE);
            const blockRelease = 1.0 - Math.pow(1.0 - state.releaseCoeff, BLOCK_SIZE);
            
            if (inputLevelDb > state.envelope) {
                state.envelope += blockAttack * (inputLevelDb - state.envelope);
            } else {
                state.envelope += blockRelease * (inputLevelDb - state.envelope);
            }
            
            // Transient fast-track: if post-EQ peak exceeds envelope, push it up
            if (peakPostEqDb > state.envelope) {
                state.envelope += state.attackCoeff * (peakPostEqDb - state.envelope);
            }
            
            if (state.envelope < WDRC_ENVELOPE_FLOOR_DB) {
                state.envelope = WDRC_ENVELOPE_FLOOR_DB;
            }
            
            // Calculate gain reduction (three-region model)
            let gainFactor = 1.0;
            if (state.envelope < state.expansionKneeDb) {
                // EXPANSION: reduce gain for noise below expansion kneepoint
                const belowKnee = state.expansionKneeDb - state.envelope;
                const gainReductionDb = belowKnee * (1.0 - 1.0 / state.expansionRatio);
                gainFactor = Math.pow(10.0, -gainReductionDb / 20.0);
            } else if (state.envelope > state.thresholdDb) {
                // COMPRESSION: reduce gain for loud sounds above compression kneepoint
                const excess = state.envelope - state.thresholdDb;
                const gainReductionDb = excess * (1.0 - 1.0 / state.ratio);
                gainFactor = Math.pow(10.0, -gainReductionDb / 20.0);
            }
            // else: LINEAR region (gainFactor = 1.0)
            
            // Headroom guard: ensure post-EQ signal × gainFactor stays below digital ceiling
            // Uses actual digital ceiling (0.95) as reference, not MPO threshold
            // This prevents the MPO from clipping (which causes THD)
            let peakLinear = 0;
            for (let i = 0; i < BLOCK_SIZE; i++) {
                const abs = Math.abs(buffer[i]);
                if (abs > peakLinear) peakLinear = abs;
            }
            const postWdrcPeak = peakLinear * gainFactor;
            const ceiling = 0.95;
            if (postWdrcPeak > ceiling) {
                gainFactor = ceiling / Math.max(peakLinear, 1e-10);
            }
            
            state.gainDb = 20.0 * Math.log10(Math.max(gainFactor, 1e-10));
            
            // Apply gain factor to block
            if (gainFactor < 1.0) {
                for (let i = 0; i < BLOCK_SIZE; i++) {
                    buffer[i] *= gainFactor;
                }
            }
        },

        reset() {
            for (let i = 0; i < NUM_BANDS; i++) {
                states[i].envelope = WDRC_ENVELOPE_FLOOR_DB;
                states[i].gainDb = 0.0;
            }
        }
    };
}

// =============================================================================
// MPO Limiter — Peak Limiter
// =============================================================================

function createMpoLimiter() {
    const state = {
        thresholdDb: 110.0,
        thresholdLinear: Math.pow(10.0, (110.0 - WDRC_DBFS_TO_SPL_OFFSET) / 20.0),
        attackCoeff: calculateTimeCoefficient(MPO_ATTACK_MS),
        releaseCoeff: calculateTimeCoefficient(MPO_RELEASE_MS),
        gain: 1.0,
        limitCounter: 0,
        sustainedWarning: false
    };

    return {
        state,

        init() {
            state.thresholdDb = 110.0;
            state.thresholdLinear = Math.pow(10.0, (110.0 - WDRC_DBFS_TO_SPL_OFFSET) / 20.0);
            state.attackCoeff = calculateTimeCoefficient(MPO_ATTACK_MS);
            state.releaseCoeff = calculateTimeCoefficient(MPO_RELEASE_MS);
            state.gain = 1.0;
            state.limitCounter = 0;
            state.sustainedWarning = false;
        },

        setThreshold(thresholdDb) {
            if (thresholdDb < VALIDATION.MPO_THRESHOLD.min ||
                thresholdDb > VALIDATION.MPO_THRESHOLD.max) return false;
            state.thresholdDb = thresholdDb;
            state.thresholdLinear = Math.pow(10.0, (thresholdDb - WDRC_DBFS_TO_SPL_OFFSET) / 20.0);
            // Clamp to max 0.99 to guarantee no digital clipping
            if (state.thresholdLinear > 0.99) state.thresholdLinear = 0.99;
            return true;
        },

        processSample(sample) {
            const absSample = Math.abs(sample);
            if (absSample > state.thresholdLinear) {
                const targetGain = state.thresholdLinear / Math.max(absSample, 1e-10);
                // Adaptive attack: continuous coefficient based on overshoot ratio²
                const overshootRatio = absSample / state.thresholdLinear;
                const adaptiveCoeff = Math.min(state.attackCoeff * Math.min(overshootRatio * overshootRatio, 16.0), 1.0);
                state.gain += adaptiveCoeff * (targetGain - state.gain);
                state.limitCounter++;
            } else {
                state.gain += state.releaseCoeff * (1.0 - state.gain);
                if (state.gain >= 0.99) {
                    state.limitCounter = 0;
                    state.sustainedWarning = false;
                }
            }
            let output = sample * state.gain;
            // Hard ceiling: absolute safety net — no sample ever exceeds ±0.99
            if (output > 0.99) output = 0.99;
            else if (output < -0.99) output = -0.99;
            return output;
        },

        processBlock(buffer) {
            for (let i = 0; i < BLOCK_SIZE; i++) {
                buffer[i] = this.processSample(buffer[i]);
            }
        },

        reset() {
            state.gain = 1.0;
            state.limitCounter = 0;
            state.sustainedWarning = false;
        }
    };
}

// =============================================================================
// Noise Reducer — Wiener Filter, 8 Sub-Bands
// =============================================================================

function createNoiseReducer() {
    const state = {
        noiseEstimate: new Float32Array(NR_SUB_BANDS),
        bandEnergy: new Float32Array(NR_SUB_BANDS),
        bandGains: new Float32Array(NR_SUB_BANDS).fill(1.0),
        smoothGains: new Float32Array(NR_SUB_BANDS).fill(1.0),
        aggressiveness: 0,
        gainFloor: 1.0,
        blockCount: 0,
        adapting: true
    };

    return {
        state,

        init() {
            state.noiseEstimate.fill(0);
            state.bandEnergy.fill(0);
            state.bandGains.fill(1.0);
            state.smoothGains.fill(1.0);
            state.aggressiveness = 0;
            state.gainFloor = 1.0;
            state.blockCount = 0;
            state.adapting = true;
        },

        setLevel(level) {
            if (level < 0 || level > 3) return;
            state.aggressiveness = level;
            state.gainFloor = NR_GAIN_FLOORS[level];
        },

        processBlock(input, output) {
            if (state.aggressiveness === 0) {
                for (let i = 0; i < BLOCK_SIZE; i++) {
                    output[i] = input[i];
                }
                return;
            }

            for (let band = 0; band < NR_SUB_BANDS; band++) {
                const start = NR_SUBBAND_BOUNDARIES[band];
                const end = NR_SUBBAND_BOUNDARIES[band + 1];
                let energy = 0.0;
                for (let i = start; i < end; i++) {
                    energy += input[i] * input[i];
                }
                state.bandEnergy[band] = energy / (end - start);
            }

            state.blockCount++;
            for (let band = 0; band < NR_SUB_BANDS; band++) {
                if (state.adapting) {
                    state.noiseEstimate[band] =
                        NR_ALPHA_NOISE * state.noiseEstimate[band] +
                        (1.0 - NR_ALPHA_NOISE) * state.bandEnergy[band];
                } else {
                    const snr = state.bandEnergy[band] /
                                (state.noiseEstimate[band] + NR_EPSILON);
                    const speechProb = snr > NR_SPEECH_THRESHOLD ? 1.0 :
                                       snr < 1.0 ? 0.0 :
                                       (snr - 1.0) / (NR_SPEECH_THRESHOLD - 1.0);
                    if (speechProb < 0.5) {
                        state.noiseEstimate[band] =
                            NR_ALPHA_NOISE * state.noiseEstimate[band] +
                            (1.0 - NR_ALPHA_NOISE) * state.bandEnergy[band];
                    }
                }
            }
            if (state.adapting && state.blockCount >= NR_ADAPTATION_BLOCKS) {
                state.adapting = false;
            }

            const beta = NR_OVERSUBTRACTION[state.aggressiveness];
            for (let band = 0; band < NR_SUB_BANDS; band++) {
                let gain;
                if (state.bandEnergy[band] < NR_EPSILON) {
                    gain = state.gainFloor;
                } else {
                    gain = 1.0 - beta * (state.noiseEstimate[band] /
                           (state.bandEnergy[band] + NR_EPSILON));
                }
                gain = Math.max(gain, state.gainFloor);
                gain = Math.min(gain, 1.0);
                state.bandGains[band] = gain;
            }

            for (let band = 0; band < NR_SUB_BANDS; band++) {
                state.smoothGains[band] =
                    NR_GAIN_SMOOTH_FACTOR * state.smoothGains[band] +
                    (1.0 - NR_GAIN_SMOOTH_FACTOR) * state.bandGains[band];
            }

            for (let band = 0; band < NR_SUB_BANDS; band++) {
                const start = NR_SUBBAND_BOUNDARIES[band];
                const end = NR_SUBBAND_BOUNDARIES[band + 1];
                const gain = state.smoothGains[band];
                for (let i = start; i < end; i++) {
                    output[i] = input[i] * gain;
                }
            }
        },

        reset() {
            this.init();
        }
    };
}

// =============================================================================
// Feedback Canceller — NLMS Adaptive Filter
// =============================================================================

function createFeedbackCanceller() {
    const state = {
        w: new Float32Array(AFC_TAPS),
        xBuf: new Float32Array(AFC_TAPS),
        mu: AFC_MU_DEFAULT,
        bufIdx: 0,
        enabled: true
    };

    return {
        state,

        init() {
            state.w.fill(0);
            state.xBuf.fill(0);
            state.mu = AFC_MU_DEFAULT;
            state.bufIdx = 0;
            state.enabled = true;
        },

        setMu(mu) {
            if (mu < AFC_MU_MIN || mu > AFC_MU_MAX) return false;
            state.mu = mu;
            return true;
        },

        enable() { state.enabled = true; },
        disable() { state.enabled = false; },

        processBlock(micInput, speakerRef, output) {
            if (!state.enabled) {
                for (let i = 0; i < BLOCK_SIZE; i++) {
                    output[i] = micInput[i];
                }
                return;
            }

            for (let i = 0; i < BLOCK_SIZE; i++) {
                state.xBuf[state.bufIdx] = speakerRef[i];

                let feedbackEstimate = 0.0;
                for (let j = 0; j < AFC_TAPS; j++) {
                    const idx = (state.bufIdx - j + AFC_TAPS) % AFC_TAPS;
                    feedbackEstimate += state.w[j] * state.xBuf[idx];
                }

                const error = micInput[i] - feedbackEstimate;

                let power = 0.0;
                for (let j = 0; j < AFC_TAPS; j++) {
                    const idx = (state.bufIdx - j + AFC_TAPS) % AFC_TAPS;
                    power += state.xBuf[idx] * state.xBuf[idx];
                }
                if (power < AFC_POWER_FLOOR) power = AFC_POWER_FLOOR;

                const normMu = state.mu / power;

                for (let j = 0; j < AFC_TAPS; j++) {
                    const idx = (state.bufIdx - j + AFC_TAPS) % AFC_TAPS;
                    state.w[j] += normMu * error * state.xBuf[idx];
                }

                state.bufIdx = (state.bufIdx + 1) % AFC_TAPS;
                output[i] = error;
            }
        },

        reset() {
            state.w.fill(0);
            state.xBuf.fill(0);
            state.bufIdx = 0;
        }
    };
}

// =============================================================================
// Master Volume & Configuration Validation
// =============================================================================

function applyMasterVolume(buffer, gainLinear) {
    for (let i = 0; i < BLOCK_SIZE; i++) {
        buffer[i] *= gainLinear;
    }
}

function validateConfig(config) {
    if (!config) return false;

    if (!config.eq_gains || config.eq_gains.length !== NUM_BANDS) return false;
    for (let i = 0; i < NUM_BANDS; i++) {
        const g = config.eq_gains[i];
        if (g < VALIDATION.EQ_GAIN.min || g > VALIDATION.EQ_GAIN.max) return false;
    }

    if (!config.agc_bands || config.agc_bands.length !== NUM_BANDS) return false;
    for (let i = 0; i < NUM_BANDS; i++) {
        const b = config.agc_bands[i];
        if (!b) return false;
        if (b.compression_ratio < VALIDATION.AGC_RATIO.min ||
            b.compression_ratio > VALIDATION.AGC_RATIO.max) return false;
        if (b.kneepoint_db < VALIDATION.AGC_KNEEPOINT.min ||
            b.kneepoint_db > VALIDATION.AGC_KNEEPOINT.max) return false;
        if (b.attack_ms < VALIDATION.AGC_ATTACK.min ||
            b.attack_ms > VALIDATION.AGC_ATTACK.max) return false;
        if (b.release_ms < VALIDATION.AGC_RELEASE.min ||
            b.release_ms > VALIDATION.AGC_RELEASE.max) return false;
    }

    if (config.mpo_threshold_db < VALIDATION.MPO_THRESHOLD.min ||
        config.mpo_threshold_db > VALIDATION.MPO_THRESHOLD.max) return false;

    if (config.noise_reduction_level < VALIDATION.NR_LEVEL.min ||
        config.noise_reduction_level > VALIDATION.NR_LEVEL.max) return false;

    if (config.feedback_enabled < VALIDATION.FEEDBACK.min ||
        config.feedback_enabled > VALIDATION.FEEDBACK.max) return false;

    if (config.master_volume_db < VALIDATION.VOLUME.min ||
        config.master_volume_db > VALIDATION.VOLUME.max) return false;

    return true;
}

// =============================================================================
// Pipeline Metrics
// =============================================================================

class PipelineMetrics {
    constructor() {
        this.inputPeak = 0.0;
        this.outputPeak = 0.0;
        this.inputRms = 0.0;
        this.outputRms = 0.0;
        this.effectiveGainDb = 0.0;
        this.mpoActivations = 0;
        this.mpoDutyCycle = 0.0;
        this.wdrcAvgGainReduction = 0.0;
        this.thd = 0.0;
        this.iec60118Compliant = true;
        this._inputSumSq = 0.0;
        this._outputSumSq = 0.0;
        this._totalSamples = 0;
        this._mpoActiveCount = 0;
    }

    reset() {
        this.inputPeak = 0.0;
        this.outputPeak = 0.0;
        this.inputRms = 0.0;
        this.outputRms = 0.0;
        this.effectiveGainDb = 0.0;
        this.mpoActivations = 0;
        this.mpoDutyCycle = 0.0;
        this.wdrcAvgGainReduction = 0.0;
        this.thd = 0.0;
        this.iec60118Compliant = true;
        this._inputSumSq = 0.0;
        this._outputSumSq = 0.0;
        this._totalSamples = 0;
        this._mpoActiveCount = 0;
    }

    updateInput(buffer) {
        for (let i = 0; i < buffer.length; i++) {
            const abs = Math.abs(buffer[i]);
            if (abs > this.inputPeak) this.inputPeak = abs;
            this._inputSumSq += buffer[i] * buffer[i];
        }
    }

    updateOutput(buffer) {
        for (let i = 0; i < buffer.length; i++) {
            const abs = Math.abs(buffer[i]);
            if (abs > this.outputPeak) this.outputPeak = abs;
            this._outputSumSq += buffer[i] * buffer[i];
        }
        this._totalSamples += buffer.length;
    }

    updateMpo(mpoState) {
        if (mpoState.gain < 0.99) {
            this._mpoActiveCount++;
            this.mpoActivations++;
        }
    }

    finalize() {
        if (this._totalSamples > 0) {
            this.inputRms = Math.sqrt(this._inputSumSq / this._totalSamples);
            this.outputRms = Math.sqrt(this._outputSumSq / this._totalSamples);
            this.mpoDutyCycle = this._mpoActiveCount / this._totalSamples;

            if (this.inputRms > 1e-10) {
                this.effectiveGainDb = 20.0 * Math.log10(this.outputRms / this.inputRms);
            }
        }
    }
}

// =============================================================================
// DSP Pipeline — Full Orchestrator
// =============================================================================

function createDspPipeline() {
    const feedbackCanceller = createFeedbackCanceller();
    const noiseReducer = createNoiseReducer();
    const equalizer = createEqualizer();
    const wdrc = createWdrcBank();
    const mpoLimiter = createMpoLimiter();

    let masterGainLinear = 1.0;
    let speakerRef = new Float32Array(BLOCK_SIZE);
    let metrics = new PipelineMetrics();

    const bufA = new Float32Array(BLOCK_SIZE);
    const bufB = new Float32Array(BLOCK_SIZE);

    function applyConfigInternal(config) {
        equalizer.setAllGains(config.eq_gains);

        for (let i = 0; i < NUM_BANDS; i++) {
            const b = config.agc_bands[i];
            wdrc.configureBand(i, {
                ratio: b.compression_ratio / 10.0,
                kneepoint: b.kneepoint_db,
                attack_ms: b.attack_ms,
                release_ms: b.release_ms
            });
        }

        mpoLimiter.setThreshold(config.mpo_threshold_db);
        wdrc.setMpoThreshold(config.mpo_threshold_db);
        noiseReducer.setLevel(config.noise_reduction_level);

        if (config.feedback_enabled) {
            feedbackCanceller.enable();
        } else {
            feedbackCanceller.disable();
        }

        masterGainLinear = dbToLinear(config.master_volume_db);
    }

    return {
        feedbackCanceller,
        noiseReducer,
        equalizer,
        wdrc,
        mpoLimiter,

        init(config) {
            feedbackCanceller.init();
            noiseReducer.init();
            equalizer.init();
            wdrc.init();
            mpoLimiter.init();
            masterGainLinear = 1.0;
            speakerRef = new Float32Array(BLOCK_SIZE);
            metrics = new PipelineMetrics();

            if (config && validateConfig(config)) {
                applyConfigInternal(config);
            }
        },

        processBlock(input) {
            const floatInput = convertInt16ToFloat(input);
            metrics.updateInput(floatInput);

            feedbackCanceller.processBlock(floatInput, speakerRef, bufA);
            noiseReducer.processBlock(bufA, bufB);
            
            // Measure input level BEFORE EQ for WDRC decision
            // Uses WDRC-specific calibration offset (76 dB) so that typical
            // WAV file levels map to reasonable SPL values for compression decisions.
            // This ensures soft sounds (< kneepoint) get full EQ amplification.
            let inputSumSq = 0;
            for (let i = 0; i < BLOCK_SIZE; i++) {
                inputSumSq += bufB[i] * bufB[i];
            }
            const inputRms = Math.sqrt(inputSumSq / BLOCK_SIZE);
            const inputLevelDb = (inputRms > 1e-10) ?
                20.0 * Math.log10(inputRms) + WDRC_DBFS_TO_SPL_OFFSET : WDRC_ENVELOPE_FLOOR_DB;
            
            equalizer.processBlock(bufB, bufA);
            wdrc.processBlockWithLevel(bufA, inputLevelDb);
            
            // Volume BEFORE MPO — so MPO catches volume-boosted peaks
            applyMasterVolume(bufA, masterGainLinear);
            
            // MPO is LAST — absolute safety guarantee (no clipping)
            mpoLimiter.processBlock(bufA);
            metrics.updateMpo(mpoLimiter.state);

            metrics.updateOutput(bufA);

            speakerRef.set(bufA);

            return convertFloatToInt16(bufA);
        },

        applyConfig(config) {
            if (!validateConfig(config)) return false;
            applyConfigInternal(config);
            return true;
        },

        getMetrics() {
            metrics.finalize();
            return { ...metrics };
        },

        reset() {
            feedbackCanceller.reset();
            noiseReducer.init();
            equalizer.resetStates();
            wdrc.reset();
            mpoLimiter.reset();
            speakerRef.fill(0);
            metrics.reset();
        },

        resetMetrics() {
            metrics.reset();
        }
    };
}

// =============================================================================
// Browser Export — window.DspEngine
// =============================================================================

window.DspEngine = {
    // Pipeline constants
    BLOCK_SIZE,
    SAMPLE_RATE,
    NUM_BANDS,
    AFC_TAPS,
    NR_SUB_BANDS,
    EQ_Q_FACTOR,
    BIQUADS_PER_BAND,
    MPO_ATTACK_MS,
    MPO_RELEASE_MS,
    MPO_DBFS_TO_SPL_OFFSET,

    // AFC constants
    AFC_MU_DEFAULT,
    AFC_MU_MIN,
    AFC_MU_MAX,
    AFC_POWER_FLOOR,

    // Noise Reducer constants
    NR_GAIN_SMOOTH_FACTOR,
    NR_ALPHA_NOISE,
    NR_ALPHA_SIGNAL,
    NR_ADAPTATION_BLOCKS,
    NR_EPSILON,
    NR_SPEECH_THRESHOLD,
    NR_ALPHA_P,

    // WDRC constants
    WDRC_ENVELOPE_FLOOR_DB,
    WDRC_DBFS_TO_SPL_OFFSET,
    WDRC_EXPANSION_KNEE_DEFAULT,
    WDRC_EXPANSION_RATIO_DEFAULT,

    // Arrays
    EQ_CENTER_FREQUENCIES,
    NR_GAIN_FLOORS,
    NR_OVERSUBTRACTION,
    NR_SUBBAND_BOUNDARIES,

    // Validation
    VALIDATION,

    // Classes
    BiquadFilter,
    PipelineMetrics,

    // Utility functions
    convertInt16ToFloat,
    convertFloatToInt16,
    calculateTimeCoefficient,
    dbToLinear,
    computeBiquadCoeffs,
    applyMasterVolume,
    validateConfig,

    // Factory functions
    createEqualizer,
    createWdrcBank,
    createMpoLimiter,
    createNoiseReducer,
    createFeedbackCanceller,
    createDspPipeline
};

})(); // End IIFE
