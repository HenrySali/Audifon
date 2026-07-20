/**
 * =============================================================================
 * DspWorkletProcessor — AudioWorklet DSP Pipeline for Realtime Hearing Aid
 *
 * Runs in a dedicated audio thread. Processes microphone audio through
 * EQ → WDRC → MPO → Volume pipeline at native sample rate.
 *
 * MessagePort Protocol (Main → Worklet):
 *   { type: 'updateParams', config: { eq_gains, wdrc_ratio, mpo_threshold, master_volume_db } }
 *   { type: 'setBypass', active: boolean }
 *   { type: 'startRecording' }
 *   { type: 'stopRecording' }
 *   { type: 'stop' }
 *
 * MessagePort Protocol (Worklet → Main):
 *   { type: 'levels', inputRms: number, outputRms: number }
 *   { type: 'overload', consecutive: number }
 *   { type: 'ready' }
 *   { type: 'recordingData', inputSamples: Float32Array, outputSamples: Float32Array }
 * =============================================================================
 */

'use strict';

class DspWorkletProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();

        // Extract initial configuration from processorOptions
        const processorOptions = (options && options.processorOptions) || {};

        // DSP configuration
        this._config = {
            eq_gains: processorOptions.eq_gains || new Array(12).fill(0),
            wdrc_ratio: processorOptions.wdrc_ratio || 2.0,
            wdrc_kneepoint: processorOptions.wdrc_kneepoint || 50.0,
            wdrc_attack_ms: processorOptions.wdrc_attack_ms || 5.0,
            wdrc_release_ms: processorOptions.wdrc_release_ms || 100.0,
            wdrc_expansion_knee: processorOptions.wdrc_expansion_knee || 35.0,
            wdrc_expansion_ratio: processorOptions.wdrc_expansion_ratio || 2.0,
            mpo_threshold: processorOptions.mpo_threshold || 110.0,
            master_volume_db: processorOptions.master_volume_db || 0.0,
            sample_rate: processorOptions.sample_rate || sampleRate
        };

        // Processing state
        this._bypassed = false;
        this._alive = true;

        // Recording state
        this._recording = false;
        this._inputRecordBuffers = [];
        this._outputRecordBuffers = [];
        this._recordedSamples = 0;
        // Max 60 seconds of recording at native sample rate
        this._maxRecordSamples = 60 * (this._config.sample_rate || sampleRate);

        // Overload detection state
        this._overloadCount = 0;
        this._blockPeriod = 128 / this._config.sample_rate; // seconds per block

        // Crossfade state for smooth bypass transitions
        this._transitioning = false;
        this._crossfadeSamples = 0;  // remaining samples in current crossfade
        this._crossfadeTotal = Math.round(this._config.sample_rate * 0.005); // 5ms crossfade
        this._crossfadeTarget = false; // target bypass state after crossfade completes
        this._pendingToggle = null;    // queued toggle for rapid toggle protection

        // Last processed block for overload fallback
        this._lastProcessedBlock = null;

        // Initialize DSP pipeline (placeholder stages for task 1.2)
        this._initPipeline(this._config);

        // Set up MessagePort communication
        this.port.onmessage = (event) => this._handleMessage(event);

        // Signal readiness to main thread
        this.port.postMessage({ type: 'ready' });
    }

    /**
     * Core audio processing callback.
     * Called by the audio system for each block of 128 samples.
     *
     * @param {Float32Array[][]} inputs - Input audio buffers
     * @param {Float32Array[][]} outputs - Output audio buffers
     * @param {Object} parameters - AudioParam values (unused)
     * @returns {boolean} - true to keep processor alive
     */
    process(inputs, outputs, parameters) {
        // FIX MATRACA: Current NR level (0-3) used by WDRC to disable
        // transient fast-track when NR is active (prevents gain pumping).
        const currentNrLevel = this._nrLevel || 0;
        // If stopped, signal removal
        if (!this._alive) {
            return false;
        }

        const input = inputs[0];
        const output = outputs[0];

        // No input connected — output silence
        if (!input || !input.length || !input[0] || input[0].length === 0) {
            for (let ch = 0; ch < output.length; ch++) {
                output[ch].fill(0);
            }
            return true;
        }

        // Measure processing start time
        const startTime = currentTime;

        // Work with first channel (mono processing)
        const inputBuffer = input[0];
        const outputBuffer = output[0];
        const blockSize = inputBuffer.length;

        // Calculate input RMS
        const inputRms = this._calculateRms(inputBuffer);

        // Always compute the processed signal (needed for crossfade and normal operation)
        const processedBuffer = new Float32Array(blockSize);
        for (let i = 0; i < blockSize; i++) {
            processedBuffer[i] = inputBuffer[i];
        }

        // Run DSP pipeline on processedBuffer
        const overloaded = this._processWithBudgetCheck(processedBuffer, startTime);

        if (overloaded && this._lastProcessedBlock && this._lastProcessedBlock.length === blockSize) {
            // Overload fallback: use last successfully processed block
            processedBuffer.set(this._lastProcessedBlock);
        }

        // Direct signal is just the input (bypass path)
        const directBuffer = inputBuffer;

        // Generate output based on bypass/crossfade state
        if (this._transitioning) {
            // Crossfade in progress — blend between source_a (fading out) and source_b (fading in)
            // Determine source_a and source_b based on crossfade direction
            // _crossfadeTarget is the state we're transitioning TO
            // If transitioning to bypassed: source_a = processed, source_b = direct
            // If transitioning to processed: source_a = direct, source_b = processed
            const source_a = this._crossfadeTarget ? processedBuffer : directBuffer;
            const source_b = this._crossfadeTarget ? directBuffer : processedBuffer;

            const N = this._crossfadeTotal;
            // k starts at (N - _crossfadeSamples) since _crossfadeSamples counts remaining
            let k = N - this._crossfadeSamples;

            for (let i = 0; i < blockSize; i++) {
                if (this._crossfadeSamples > 0) {
                    // Linear crossfade: output = (1 - k/N) * source_a + (k/N) * source_b
                    const ratio = k / N;
                    outputBuffer[i] = (1.0 - ratio) * source_a[i] + ratio * source_b[i];
                    k++;
                    this._crossfadeSamples--;
                } else {
                    // Crossfade completed mid-block — output target signal for remaining samples
                    if (this._crossfadeTarget) {
                        outputBuffer[i] = directBuffer[i];
                    } else {
                        outputBuffer[i] = processedBuffer[i];
                    }
                }
            }

            // Check if crossfade completed during this block
            if (this._crossfadeSamples <= 0) {
                this._transitioning = false;
                this._bypassed = this._crossfadeTarget;

                // Check for pending toggle (rapid toggle protection)
                if (this._pendingToggle !== null) {
                    const pendingTarget = this._pendingToggle;
                    this._pendingToggle = null;
                    // Only start new crossfade if pending target differs from current state
                    if (pendingTarget !== this._bypassed) {
                        this._startCrossfade(pendingTarget);
                    }
                }
            }
        } else if (this._bypassed) {
            // Bypass mode — copy input directly to output
            for (let i = 0; i < blockSize; i++) {
                outputBuffer[i] = directBuffer[i];
            }
        } else {
            // Normal processing mode — use processed signal
            for (let i = 0; i < blockSize; i++) {
                outputBuffer[i] = processedBuffer[i];
            }
        }

        // Calculate output RMS
        const outputRms = this._calculateRms(outputBuffer);

        // Accumulate recording data if recording is active
        if (this._recording && this._recordedSamples < this._maxRecordSamples) {
            const remaining = this._maxRecordSamples - this._recordedSamples;
            const samplesToRecord = Math.min(blockSize, remaining);
            this._inputRecordBuffers.push(new Float32Array(inputBuffer.subarray(0, samplesToRecord)));
            this._outputRecordBuffers.push(new Float32Array(outputBuffer.subarray(0, samplesToRecord)));
            this._recordedSamples += samplesToRecord;
            // Auto-stop at max duration
            if (this._recordedSamples >= this._maxRecordSamples) {
                this._stopAndSendRecording();
            }
        }

        // Copy processed mono to all output channels
        for (let ch = 1; ch < output.length; ch++) {
            output[ch].set(outputBuffer);
        }

        // Store last processed block for overload fallback (only when not overloaded)
        if (!overloaded) {
            if (!this._lastProcessedBlock || this._lastProcessedBlock.length !== blockSize) {
                this._lastProcessedBlock = new Float32Array(blockSize);
            }
            this._lastProcessedBlock.set(processedBuffer);
        }

        // Report levels to main thread
        this._reportLevels(inputRms, outputRms);

        // Measure processing end time and check budget
        const endTime = currentTime;
        this._checkProcessingBudget(startTime, endTime);

        return true;
    }

    /**
     * Process audio through the DSP pipeline with overload detection.
     * Returns true if processing was overloaded (exceeded budget).
     *
     * @param {Float32Array} buffer - Audio buffer (modified in-place)
     * @param {number} startTime - Processing start time for budget check
     * @returns {boolean} - true if overloaded
     */
    _processWithBudgetCheck(buffer, startTime) {
        // Run DSP pipeline: EQ → WDRC → Volume → MPO
        //
        // CRITICAL ORDER: Volume BEFORE MPO so MPO protects against volume boost.
        // MPO is ALWAYS the last processing stage before output.
        //
        // WDRC model: measures INPUT level, then modulates the EQ gain.
        // - Soft sounds (< kneepoint): full EQ gain applied
        // - Medium sounds (> kneepoint): EQ gain reduced by compression ratio
        // - Result: output is ALWAYS louder than input at frequencies with hearing loss
        
        // 1. Measure input level BEFORE any processing
        const inputLevel = this._calculateBlockLevel(buffer);
        
        // 2. Apply EQ (frequency-shaped amplification from NAL-NL2)
        this._processEqualizer(buffer);
        
        // 3. Apply WDRC as gain modulator based on INPUT level
        // FIX MATRACA: Pass NR level so WDRC can disable transient fast-track
        this._processWdrc(buffer, inputLevel, this._nrLevel || 0);
        
        // 4. Master volume (BEFORE MPO — so MPO catches volume-boosted peaks)
        this._applyMasterVolume(buffer);
        
        // 5. MPO peak limiter (LAST stage — absolute safety guarantee)
        this._processMpo(buffer);
        
        return false;
    }

    /**
     * Calculate block-level in dB SPL for WDRC input measurement.
     * Uses RMS of the block converted to dB SPL with WDRC calibration offset.
     * The WDRC offset (76 dB) maps typical WAV levels to reasonable SPL values:
     *   -26 dBFS ≈ 50 dB SPL (soft conversation)
     *   -6 dBFS ≈ 70 dB SPL (loud speech)
     * @param {Float32Array} buffer
     * @returns {number} Level in dB SPL (WDRC-calibrated)
     */
    _calculateBlockLevel(buffer) {
        let sumSq = 0;
        for (let i = 0; i < buffer.length; i++) {
            sumSq += buffer[i] * buffer[i];
        }
        const rms = Math.sqrt(sumSq / buffer.length);
        if (rms < 1e-10) return this._WDRC_ENVELOPE_FLOOR_DB;
        // Use same calibration offset for both modes (76 dB).
        // The WDRC decision is based on input level mapped to SPL.
        return 20.0 * Math.log10(rms) + this._WDRC_DBFS_TO_SPL_OFFSET;
    }

    /**
     * Start a crossfade transition to the target bypass state.
     * @param {boolean} targetBypassed - The target bypass state
     */
    _startCrossfade(targetBypassed) {
        this._transitioning = true;
        this._crossfadeTarget = targetBypassed;
        this._crossfadeSamples = this._crossfadeTotal;
    }

    /**
     * Handle messages from the main thread via MessagePort.
     * @param {MessageEvent} event
     */
    _handleMessage(event) {
        const data = event.data;

        switch (data.type) {
            case 'updateParams':
                if (data.config) {
                    // Hot-update parameters without resetting filter states
                    // This avoids audible discontinuities during parameter changes

                    // Update EQ gains (recalculate coefficients, preserve z1/z2 state)
                    if (data.config.eq_gains !== undefined) {
                        this._config.eq_gains = data.config.eq_gains;
                        for (let band = 0; band < this._NUM_BANDS; band++) {
                            this._setEqBandGain(band, data.config.eq_gains[band] || 0);
                        }
                    }

                    // Update WDRC parameters (preserve envelope state)
                    if (data.config.wdrc_ratio !== undefined) {
                        this._config.wdrc_ratio = data.config.wdrc_ratio;
                        this._wdrcState.ratio = data.config.wdrc_ratio;
                    }
                    if (data.config.wdrc_kneepoint !== undefined) {
                        this._config.wdrc_kneepoint = data.config.wdrc_kneepoint;
                        this._wdrcState.thresholdDb = data.config.wdrc_kneepoint;
                    }
                    if (data.config.wdrc_attack_ms !== undefined) {
                        this._config.wdrc_attack_ms = data.config.wdrc_attack_ms;
                        this._wdrcState.attackCoeff = this._calcTimeCoeff(data.config.wdrc_attack_ms, this._config.sample_rate);
                    }
                    if (data.config.wdrc_release_ms !== undefined) {
                        this._config.wdrc_release_ms = data.config.wdrc_release_ms;
                        this._wdrcState.releaseCoeff = this._calcTimeCoeff(data.config.wdrc_release_ms, this._config.sample_rate);
                    }

                    // Update MPO threshold (preserve gain state)
                    if (data.config.mpo_threshold !== undefined) {
                        this._config.mpo_threshold = data.config.mpo_threshold;
                        this._mpoState.thresholdDb = data.config.mpo_threshold;
                        let newThreshLinear = Math.pow(10.0,
                            (data.config.mpo_threshold - this._WDRC_DBFS_TO_SPL_OFFSET) / 20.0);
                        if (newThreshLinear > 0.99) newThreshLinear = 0.99;
                        this._mpoState.thresholdLinear = newThreshLinear;
                        this._mpoThresholdSpl = data.config.mpo_threshold;
                    }

                    // Update WDRC expansion parameters (preserve envelope state)
                    if (data.config.wdrc_expansion_knee !== undefined) {
                        this._config.wdrc_expansion_knee = data.config.wdrc_expansion_knee;
                        this._wdrcState.expansionKneeDb = data.config.wdrc_expansion_knee;
                    }
                    if (data.config.wdrc_expansion_ratio !== undefined) {
                        this._config.wdrc_expansion_ratio = data.config.wdrc_expansion_ratio;
                        this._wdrcState.expansionRatio = data.config.wdrc_expansion_ratio;
                    }

                    // Update master volume
                    if (data.config.master_volume_db !== undefined) {
                        this._config.master_volume_db = data.config.master_volume_db;
                        this._masterGainLinear = Math.pow(10.0, data.config.master_volume_db / 20.0);
                    }

                    // FIX MATRACA: Update NR level so WDRC/MPO can adapt
                    if (data.config.nr_level !== undefined) {
                        this._nrLevel = data.config.nr_level;
                    }
                }
                break;

            case 'setBypass':
                {
                    const targetState = !!data.active;
                    // Only act if the target differs from current/pending state
                    if (this._transitioning) {
                        // Rapid toggle protection: queue at most one pending toggle
                        // Complete current transition first, then start new one
                        if (targetState !== this._crossfadeTarget) {
                            this._pendingToggle = targetState;
                        } else {
                            // Same as current target — discard (no-op)
                            this._pendingToggle = null;
                        }
                    } else if (targetState !== this._bypassed) {
                        // No transition in progress and state differs — start crossfade
                        this._startCrossfade(targetState);
                    }
                    // If targetState === this._bypassed and not transitioning, no-op
                }
                break;

            case 'stop':
                this._alive = false;
                break;

            case 'startRecording':
                this._recording = true;
                this._inputRecordBuffers = [];
                this._outputRecordBuffers = [];
                this._recordedSamples = 0;
                break;

            case 'stopRecording':
                this._stopAndSendRecording();
                break;
        }
    }

    /**
     * Stop recording and send accumulated data to main thread via transferable.
     */
    _stopAndSendRecording() {
        this._recording = false;
        const totalSamples = this._recordedSamples;

        if (totalSamples === 0) {
            this.port.postMessage({
                type: 'recordingData',
                inputSamples: new Float32Array(0),
                outputSamples: new Float32Array(0)
            });
            return;
        }

        // Concatenate all recorded chunks into single Float32Arrays
        const inputSamples = new Float32Array(totalSamples);
        const outputSamples = new Float32Array(totalSamples);
        let offset = 0;
        for (let i = 0; i < this._inputRecordBuffers.length; i++) {
            inputSamples.set(this._inputRecordBuffers[i], offset);
            outputSamples.set(this._outputRecordBuffers[i], offset);
            offset += this._inputRecordBuffers[i].length;
        }

        // Free memory
        this._inputRecordBuffers = [];
        this._outputRecordBuffers = [];
        this._recordedSamples = 0;

        // Send via transferable to avoid copying
        this.port.postMessage(
            { type: 'recordingData', inputSamples: inputSamples, outputSamples: outputSamples },
            [inputSamples.buffer, outputSamples.buffer]
        );
    }

    /**
     * Initialize the DSP pipeline with given configuration.
     * Sets up biquad filter states for 12 bands × 2 biquads, WDRC envelope state, MPO state.
     * Ported from dsp-engine-browser.js, adapted for native sample rate.
     * @param {Object} config
     */
    _initPipeline(config) {
        const sRate = config.sample_rate || sampleRate;

        // --- Constants (from dsp-engine-browser.js) ---
        this._NUM_BANDS = 12;
        this._BIQUADS_PER_BAND = 2;
        this._EQ_Q_FACTOR = 2.0;
        this._MPO_DBFS_TO_SPL_OFFSET = 120.0;
        this._WDRC_DBFS_TO_SPL_OFFSET = 76.0;  // WDRC calibration: -26 dBFS ≈ 50 dB SPL
        this._WDRC_ENVELOPE_FLOOR_DB = 0.0;
        // Realtime mode calibration offset for browser microphones.
        // Browser mics (getUserMedia) with AGC disabled deliver speech at ~-37 dBFS RMS.
        // We want normal speech to fall in the WDRC linear region (between expansion
        // knee 35 dB SPL and compression knee 50 dB SPL).
        // With offset 76: -37 dBFS + 76 = 39 dB SPL → linear region ✓
        // Using same offset as WAV mode because browser mic levels after OS gain
        // are comparable to typical WAV recording levels.
        this._REALTIME_DBFS_TO_SPL_OFFSET = config.realtime_offset || 76.0;
        this._realtimeMode = true;
        this._EQ_CENTER_FREQUENCIES = [
            250, 500, 750, 1000, 1500, 2000,
            2500, 3000, 3500, 4000, 6000, 8000
        ];

        // --- Equalizer: 12 bands × 2 biquad filters ---
        // Each biquad stores: b0, b1, b2, a1, a2, z1, z2
        this._eqFilters = [];
        for (let band = 0; band < this._NUM_BANDS; band++) {
            this._eqFilters[band] = [];
            for (let bq = 0; bq < this._BIQUADS_PER_BAND; bq++) {
                this._eqFilters[band][bq] = {
                    b0: 1.0, b1: 0.0, b2: 0.0,
                    a1: 0.0, a2: 0.0,
                    z1: 0.0, z2: 0.0
                };
            }
        }
        this._eqGainsDb = new Float32Array(this._NUM_BANDS);

        // Compute initial EQ coefficients for native sample rate
        this._eqSampleRate = sRate;
        if (config.eq_gains) {
            for (let band = 0; band < this._NUM_BANDS; band++) {
                this._setEqBandGain(band, config.eq_gains[band] || 0);
            }
        }

        // --- WDRC: single-band compressor state ---
        const attackMs = config.wdrc_attack_ms || 5.0;
        const releaseMs = config.wdrc_release_ms || 100.0;
        this._wdrcState = {
            thresholdDb: config.wdrc_kneepoint || 50.0,
            ratio: config.wdrc_ratio || 2.0,
            expansionKneeDb: config.wdrc_expansion_knee || 35.0,
            expansionRatio: config.wdrc_expansion_ratio || 2.0,
            attackCoeff: this._calcTimeCoeff(attackMs, sRate),
            releaseCoeff: this._calcTimeCoeff(releaseMs, sRate),
            envelope: this._WDRC_ENVELOPE_FLOOR_DB,
            gainDb: 0.0
        };

        // --- MPO Limiter state ---
        const mpoThresholdDb = config.mpo_threshold || 110.0;
        const mpoAttackMs = 0.5;
        const mpoReleaseMs = 10.0;
        let mpoThreshLinear = Math.pow(10.0, (mpoThresholdDb - this._WDRC_DBFS_TO_SPL_OFFSET) / 20.0);
        if (mpoThreshLinear > 0.99) mpoThreshLinear = 0.99;
        // FIX MATRACA: Hold time of 1ms before release to prevent oscillation
        const mpoHoldMs = 1.0;
        const mpoHoldSamples = Math.round(mpoHoldMs * sRate / 1000.0);
        this._mpoState = {
            thresholdDb: mpoThresholdDb,
            thresholdLinear: mpoThreshLinear,
            attackCoeff: this._calcTimeCoeff(mpoAttackMs, sRate),
            releaseCoeff: this._calcTimeCoeff(mpoReleaseMs, sRate),
            gain: 1.0,
            holdSamples: 0,
            holdTotal: mpoHoldSamples
        };
        this._mpoThresholdSpl = mpoThresholdDb;

        // --- Master Volume ---
        this._masterGainLinear = Math.pow(10.0, (config.master_volume_db || 0.0) / 20.0);

        // --- NR Level state (FIX MATRACA) ---
        // Tracks the current noise reduction level (0-3) so the WDRC and MPO
        // can adapt their behavior when NR is active.
        this._nrLevel = config.nr_level || 0;

        this._pipelineReady = true;
    }

    /**
     * Calculate time coefficient for envelope follower.
     * Ported from dsp-engine-browser.js calculateTimeCoefficient().
     * @param {number} timeMs - Time constant in milliseconds
     * @param {number} sr - Sample rate
     * @returns {number} Coefficient per sample
     */
    _calcTimeCoeff(timeMs, sr) {
        const samples = timeMs * sr / 1000.0;
        return 1.0 - Math.exp(-1.0 / Math.max(samples, 1.0));
    }

    /**
     * Compute biquad peaking EQ coefficients for a given band and gain.
     * Ported from dsp-engine-browser.js computeBiquadCoeffs().
     * Recalculates for native sample rate (not 16kHz).
     * @param {number} band - Band index (0-11)
     * @param {number} gainDb - Total gain for this band in dB (0-50)
     */
    _setEqBandGain(band, gainDb) {
        if (band < 0 || band >= this._NUM_BANDS) return;
        gainDb = Math.max(0, Math.min(gainDb, 50));
        this._eqGainsDb[band] = gainDb;

        // Adaptive Q: higher gain → narrower band to reduce overlap
        const baseQ = this._EQ_Q_FACTOR;
        const adaptiveQ = gainDb <= 6.0 ? baseQ : Math.min(baseQ * (1.0 + (gainDb - 6.0) / 20.0), 4.5);

        // First biquad: full gain with adaptive Q
        const filter = this._eqFilters[band][0];
        if (gainDb <= 0.0) {
            filter.b0 = 1.0; filter.b1 = 0.0; filter.b2 = 0.0;
            filter.a1 = 0.0; filter.a2 = 0.0;
        } else {
            const A = Math.pow(10.0, gainDb / 40.0);
            const nyquist = this._eqSampleRate / 2;
            let w0, sinW0, cosW0, alpha, b0, b1, b2, a0, a1, a2;
            if (this._EQ_CENTER_FREQUENCIES[band] > nyquist * 0.85) {
                // High-shelf at 0.25 × Nyquist with S=0.4 for full gain delivery by 6-7 kHz
                const shelfFc = nyquist * 0.25;
                w0 = 2.0 * Math.PI * shelfFc / this._eqSampleRate;
                sinW0 = Math.sin(w0);
                cosW0 = Math.cos(w0);
                const S = 0.4;
                alpha = sinW0 / 2.0 * Math.sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
                b0 = A * ((A + 1) + (A - 1) * cosW0 + 2 * Math.sqrt(A) * alpha);
                b1 = -2 * A * ((A - 1) + (A + 1) * cosW0);
                b2 = A * ((A + 1) + (A - 1) * cosW0 - 2 * Math.sqrt(A) * alpha);
                a0 = (A + 1) - (A - 1) * cosW0 + 2 * Math.sqrt(A) * alpha;
                a1 = 2 * ((A - 1) - (A + 1) * cosW0);
                a2 = (A + 1) - (A - 1) * cosW0 - 2 * Math.sqrt(A) * alpha;
            } else {
                const maxFc = this._eqSampleRate * 0.45;
                const effectiveFc = Math.min(this._EQ_CENTER_FREQUENCIES[band], maxFc);
                w0 = 2.0 * Math.PI * effectiveFc / this._eqSampleRate;
                sinW0 = Math.sin(w0);
                cosW0 = Math.cos(w0);
                alpha = sinW0 / (2.0 * adaptiveQ);
                b0 = 1.0 + alpha * A;
                b1 = -2.0 * cosW0;
                b2 = 1.0 - alpha * A;
                a0 = 1.0 + alpha / A;
                a1 = -2.0 * cosW0;
                a2 = 1.0 - alpha / A;
            }

            const invA0 = 1.0 / a0;
            filter.b0 = b0 * invA0;
            filter.b1 = b1 * invA0;
            filter.b2 = b2 * invA0;
            filter.a1 = a1 * invA0;
            filter.a2 = a2 * invA0;
        }
        // Second biquad: passthrough (1 biquad per band, not cascade)
        const filter2 = this._eqFilters[band][1];
        filter2.b0 = 1.0; filter2.b1 = 0.0; filter2.b2 = 0.0;
        filter2.a1 = 0.0; filter2.a2 = 0.0;
    }

    /**
     * Process audio through 12-band parametric equalizer.
     * Ported from dsp-engine-browser.js createEqualizer().processBlock().
     * Uses Direct Form II Transposed biquad cascade.
     * Includes denormal/NaN protection for numerical stability at high sample rates.
     * @param {Float32Array} buffer - Audio buffer (modified in-place)
     */
    _processEqualizer(buffer) {
        const len = buffer.length;
        for (let band = 0; band < this._NUM_BANDS; band++) {
            if (this._eqGainsDb[band] === 0) continue;
            const bq0 = this._eqFilters[band][0];
            const bq1 = this._eqFilters[band][1];
            for (let n = 0; n < len; n++) {
                // First biquad in cascade
                let x = buffer[n];
                let y = bq0.b0 * x + bq0.z1;
                bq0.z1 = bq0.b1 * x - bq0.a1 * y + bq0.z2;
                bq0.z2 = bq0.b2 * x - bq0.a2 * y;

                // Second biquad in cascade
                x = y;
                y = bq1.b0 * x + bq1.z1;
                bq1.z1 = bq1.b1 * x - bq1.a1 * y + bq1.z2;
                bq1.z2 = bq1.b2 * x - bq1.a2 * y;

                buffer[n] = y;
            }
            // Flush denormals and catch NaN/Infinity in filter states
            // This prevents numerical instability from accumulating across blocks
            if (!isFinite(bq0.z1)) bq0.z1 = 0;
            if (!isFinite(bq0.z2)) bq0.z2 = 0;
            if (!isFinite(bq1.z1)) bq1.z1 = 0;
            if (!isFinite(bq1.z2)) bq1.z2 = 0;
            // Flush denormals (very small values that slow down FPU)
            if (Math.abs(bq0.z1) < 1e-30) bq0.z1 = 0;
            if (Math.abs(bq0.z2) < 1e-30) bq0.z2 = 0;
            if (Math.abs(bq1.z1) < 1e-30) bq1.z1 = 0;
            if (Math.abs(bq1.z2) < 1e-30) bq1.z2 = 0;
        }
        // Final safety: clamp any NaN/Infinity samples in output
        for (let n = 0; n < len; n++) {
            if (!isFinite(buffer[n])) buffer[n] = 0;
        }
    }

    /**
     * Process audio through Wide Dynamic Range Compression.
     * Ported from dsp-engine-browser.js createWdrcBank().processBlock().
     * Single-band WDRC with attack/release envelope following.
     * @param {Float32Array} buffer - Audio buffer (modified in-place)
     */
    /**
     * Process audio through WDRC (Wide Dynamic Range Compression).
     * 
     * HEARING AID MODEL: The WDRC modulates the EQ gain based on INPUT level.
     * - Input level < kneepoint: full EQ gain preserved (gain factor = 1.0)
     * - Input level > kneepoint: EQ gain reduced by compression ratio
     * 
     * Formula: gainReduction = (inputLevel - kneepoint) * (1 - 1/ratio)
     * Applied gain factor = 10^(-gainReduction / 20)
     * 
     * This ensures soft sounds get full amplification and loud sounds get
     * reduced (but still positive) amplification. The output is ALWAYS
     * louder than the input at frequencies with hearing loss.
     *
     * FIX MATRACA: Added nrLevel parameter. When NR >= 1, the transient
     * fast-track is disabled to prevent gain pumping from NR residuals
     * being misinterpreted as real transients.
     *
     * @param {Float32Array} buffer - Audio buffer post-EQ (modified in-place)
     * @param {number} inputLevelDb - Input level in dB SPL (measured before EQ)
     * @param {number} nrLevel - Current noise reduction level (0-3)
     */
    _processWdrc(buffer, inputLevelDb, nrLevel) {
        const state = this._wdrcState;
        const blockSize = buffer.length;
        
        // If no pre-measured input level provided, measure from the buffer
        if (inputLevelDb === undefined || inputLevelDb === null) {
            inputLevelDb = this._calculateBlockLevel(buffer);
        }
        
        // Sample-by-sample peak detection on post-EQ buffer
        let peakPostEqDb = this._WDRC_ENVELOPE_FLOOR_DB;
        const splOffset = this._WDRC_DBFS_TO_SPL_OFFSET || 76.0;
        for (let i = 0; i < blockSize; i++) {
            const sampleLevel = Math.abs(buffer[i]);
            const sampleDb = (sampleLevel > 1e-10) ?
                20.0 * Math.log10(sampleLevel) + splOffset :
                this._WDRC_ENVELOPE_FLOOR_DB;
            if (sampleDb > peakPostEqDb) {
                peakPostEqDb = sampleDb;
            }
        }
        
        // Envelope follower on INPUT level (block-rate update)
        const blockAttack = 1.0 - Math.pow(1.0 - state.attackCoeff, blockSize);
        const blockRelease = 1.0 - Math.pow(1.0 - state.releaseCoeff, blockSize);
        
        if (inputLevelDb > state.envelope) {
            state.envelope += blockAttack * (inputLevelDb - state.envelope);
        } else {
            state.envelope += blockRelease * (inputLevelDb - state.envelope);
        }
        
        // Transient fast-track
        // FIX MATRACA: Only use fast-track when NR is off (nrLevel == 0).
        // When NR is active, the DNN denoiser leaves short residual peaks
        // that the fast-track misinterprets as real transients, causing
        // gain pumping (the "matraca" artifact). With NR active, we rely
        // solely on the block-rate envelope follower which is smooth enough
        // to avoid oscillation.
        if (nrLevel === undefined || nrLevel === null) nrLevel = 0;
        if (nrLevel === 0 && peakPostEqDb > state.envelope) {
            state.envelope += state.attackCoeff * (peakPostEqDb - state.envelope);
        }
        
        if (state.envelope < this._WDRC_ENVELOPE_FLOOR_DB) {
            state.envelope = this._WDRC_ENVELOPE_FLOOR_DB;
        }

        // Calculate gain reduction based on three-region model
        let gainFactor = 1.0;
        
        if (state.envelope < state.expansionKneeDb) {
            const belowKnee = state.expansionKneeDb - state.envelope;
            const gainReductionDb = belowKnee * (1.0 - 1.0 / state.expansionRatio);
            gainFactor = Math.pow(10.0, -gainReductionDb / 20.0);
        } else if (state.envelope > state.thresholdDb) {
            const excess = state.envelope - state.thresholdDb;
            const gainReductionDb = excess * (1.0 - 1.0 / state.ratio);
            gainFactor = Math.pow(10.0, -gainReductionDb / 20.0);
        }
        
        // Headroom guard: ensure post-EQ signal × gainFactor stays below digital ceiling
        // Uses actual digital ceiling (0.95) as reference, not MPO threshold
        // This prevents the MPO from clipping (which causes THD)
        let peakLinear = 0;
        for (let i = 0; i < blockSize; i++) {
            const abs = Math.abs(buffer[i]);
            if (abs > peakLinear) peakLinear = abs;
        }
        const postWdrcPeak = peakLinear * gainFactor;
        const ceiling = 0.95;
        if (postWdrcPeak > ceiling) {
            gainFactor = ceiling / Math.max(peakLinear, 1e-10);
        }
        
        // Apply gain factor to the entire block
        if (gainFactor < 1.0) {
            for (let i = 0; i < blockSize; i++) {
                buffer[i] *= gainFactor;
            }
        }
        
        // Store for diagnostics
        state.gainDb = 20.0 * Math.log10(Math.max(gainFactor, 1e-10));
    }

    /**
     * Process audio through Maximum Power Output limiter.
     * Ported from dsp-engine-browser.js createMpoLimiter().processBlock().
     * Peak limiter with fast attack and slow release.
     *
     * FIX MATRACA: Softened adaptive attack from overshootRatio² cap 16 to
     * overshootRatio^1.5 cap 4. Added 1ms hold time before release to
     * prevent oscillation when NR residuals cause rapid above/below
     * threshold alternation.
     *
     * @param {Float32Array} buffer - Audio buffer (modified in-place)
     */
    _processMpo(buffer) {
        const state = this._mpoState;
        const len = buffer.length;
        for (let i = 0; i < len; i++) {
            const absSample = Math.abs(buffer[i]);
            if (absSample > state.thresholdLinear) {
                const targetGain = state.thresholdLinear / Math.max(absSample, 1e-10);
                // FIX MATRACA: Softer adaptive attack — overshootRatio^1.5 cap 4
                // (was overshootRatio² cap 16). Reduces the abrupt gain steps that
                // were audible as clicks/rattle in noisy environments.
                const overshootRatio = absSample / state.thresholdLinear;
                const adaptiveCoeff = Math.min(state.attackCoeff * Math.min(Math.pow(overshootRatio, 1.5), 4.0), 1.0);
                state.gain += adaptiveCoeff * (targetGain - state.gain);
                // FIX MATRACA: Reset hold counter — MPO is actively limiting
                state.holdSamples = state.holdTotal;
            } else {
                // FIX MATRACA: Hold time before release — prevents oscillation
                // when signal rapidly alternates above/below threshold (NR residuals).
                // Only release gain after hold period expires.
                if (state.holdSamples > 0) {
                    state.holdSamples--;
                } else {
                    state.gain += state.releaseCoeff * (1.0 - state.gain);
                }
            }
            let output = buffer[i] * state.gain;
            // Hard ceiling: absolute safety net — no sample ever exceeds ±0.99
            if (output > 0.99) output = 0.99;
            else if (output < -0.99) output = -0.99;
            buffer[i] = output;
        }
    }

    /**
     * Apply master volume gain to audio buffer.
     * Converts dB to linear gain: Math.pow(10, db / 20).
     * @param {Float32Array} buffer - Audio buffer (modified in-place)
     */
    _applyMasterVolume(buffer) {
        const gain = this._masterGainLinear;
        if (gain === 1.0) return; // Skip if unity gain
        const len = buffer.length;
        for (let i = 0; i < len; i++) {
            buffer[i] *= gain;
        }
    }

    /**
     * Calculate RMS (Root Mean Square) of an audio buffer.
     * Ported from dsp-engine-browser.js PipelineMetrics.
     *
     * @param {Float32Array} buffer - Audio samples
     * @returns {number} RMS value (0.0 to ~1.0 for normalized audio)
     */
    _calculateRms(buffer) {
        if (!buffer || buffer.length === 0) {
            return 0.0;
        }

        let sumSquares = 0.0;
        for (let i = 0; i < buffer.length; i++) {
            sumSquares += buffer[i] * buffer[i];
        }

        return Math.sqrt(sumSquares / buffer.length);
    }

    /**
     * Report input/output levels to the main thread via MessagePort.
     *
     * @param {number} inputRms - Input signal RMS
     * @param {number} outputRms - Output signal RMS
     */
    _reportLevels(inputRms, outputRms) {
        this.port.postMessage({
            type: 'levels',
            inputRms: inputRms,
            outputRms: outputRms
        });
    }

    /**
     * Check if processing exceeded the CPU budget.
     * If processing takes >30% of block period for 3 consecutive blocks,
     * posts an overload message to the main thread.
     *
     * @param {number} startTime - Processing start time (from currentTime)
     * @param {number} endTime - Processing end time (from currentTime)
     */
    _checkProcessingBudget(startTime, endTime) {
        const processingTime = endTime - startTime;
        const budgetRatio = processingTime / this._blockPeriod;

        if (budgetRatio > 0.3) {
            // Exceeded 30% of block budget
            this._overloadCount++;

            if (this._overloadCount >= 3) {
                // 3 consecutive overloaded blocks — notify main thread
                this.port.postMessage({
                    type: 'overload',
                    consecutive: this._overloadCount
                });
            }
        } else {
            // Processing within budget — reset counter
            this._overloadCount = 0;
        }
    }
}

// Register the processor with the AudioWorklet system
registerProcessor('dsp-worklet-processor', DspWorkletProcessor);
