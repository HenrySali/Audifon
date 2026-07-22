/**
 * =============================================================================
 * RealtimeRecorder — Record input/output audio from realtime DSP session
 *
 * Captures raw microphone (input) and processed (output) audio during a
 * realtime hearing aid session, then downloads them as WAV files plus a
 * config.m Octave/MATLAB script for offline analysis.
 *
 * Depends on: window.RealtimeModule (for worklet port access)
 * Exposes: window.RealtimeRecorder
 * =============================================================================
 */

'use strict';

(function () {

    // =========================================================================
    // WAV Encoder (inline, 16-bit PCM mono)
    // =========================================================================

    /**
     * Encode a Float32Array of mono samples into a 16-bit PCM WAV file blob.
     * @param {Float32Array} samples - Audio samples in [-1, 1] range
     * @param {number} sampleRate - Sample rate in Hz
     * @returns {Blob} WAV file as a Blob
     */
    function encodeWav(samples, sampleRate) {
        var numChannels = 1;
        var bitsPerSample = 16;
        var bytesPerSample = bitsPerSample / 8;
        var blockAlign = numChannels * bytesPerSample;
        var dataLength = samples.length * blockAlign;
        var bufferLength = 44 + dataLength;
        var buffer = new ArrayBuffer(bufferLength);
        var view = new DataView(buffer);

        // RIFF header
        writeString(view, 0, 'RIFF');
        view.setUint32(4, bufferLength - 8, true);
        writeString(view, 8, 'WAVE');

        // fmt sub-chunk
        writeString(view, 12, 'fmt ');
        view.setUint32(16, 16, true);              // Sub-chunk size (PCM = 16)
        view.setUint16(20, 1, true);               // Audio format (PCM = 1)
        view.setUint16(22, numChannels, true);     // Number of channels
        view.setUint32(24, sampleRate, true);      // Sample rate
        view.setUint32(28, sampleRate * blockAlign, true); // Byte rate
        view.setUint16(32, blockAlign, true);      // Block align
        view.setUint16(34, bitsPerSample, true);   // Bits per sample

        // data sub-chunk
        writeString(view, 36, 'data');
        view.setUint32(40, dataLength, true);

        // Write PCM samples (clamp to [-1, 1] then scale to int16)
        var offset = 44;
        for (var i = 0; i < samples.length; i++) {
            var s = Math.max(-1, Math.min(1, samples[i]));
            var val = s < 0 ? s * 0x8000 : s * 0x7FFF;
            view.setInt16(offset, val, true);
            offset += 2;
        }

        return new Blob([buffer], { type: 'audio/wav' });
    }

    /**
     * Write an ASCII string into a DataView at the given offset.
     * @param {DataView} view
     * @param {number} offset
     * @param {string} str
     */
    function writeString(view, offset, str) {
        for (var i = 0; i < str.length; i++) {
            view.setUint8(offset + i, str.charCodeAt(i));
        }
    }

    // =========================================================================
    // File Download Helper
    // =========================================================================

    /**
     * Trigger a file download using a temporary <a> element.
     * @param {Blob|string} content - Blob or text content
     * @param {string} filename - Download filename
     * @param {string} [mimeType] - MIME type for text content
     */
    function downloadFile(content, filename, mimeType) {
        var blob;
        if (content instanceof Blob) {
            blob = content;
        } else {
            blob = new Blob([content], { type: mimeType || 'text/plain' });
        }
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = filename;
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        // Cleanup after a short delay
        setTimeout(function () {
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        }, 200);
    }

    // =========================================================================
    // Config.m Generator
    // =========================================================================

    /**
     * Generate an Octave/MATLAB config script with current DSP parameters.
     * @param {number} sampleRate - Recording sample rate
     * @param {number} durationSeconds - Recording duration in seconds
     * @returns {string} MATLAB/Octave script content
     */
    function generateConfigM(sampleRate, durationSeconds) {
        var timestamp = new Date().toISOString();

        // Read DSP config from global state
        var eqGains = window.currentEqGains || new Array(12).fill(0);
        var wdrcRatio = window.currentWdrcRatio || 2.0;
        var wdrcKneepoint = window.currentWdrcKneepoint || 50.0;
        var wdrcAttackMs = window.currentWdrcAttackMs || 5.0;
        var wdrcReleaseMs = window.currentWdrcReleaseMs || 100.0;
        var mpoThreshold = window.currentMpoThreshold || 110.0;
        var masterVolumeDb = window.currentMasterVolumeDb || 0.0;

        // Format EQ gains as comma-separated values
        var eqGainsStr = '';
        for (var i = 0; i < 12; i++) {
            if (i > 0) eqGainsStr += ', ';
            eqGainsStr += (eqGains[i] || 0).toFixed(1);
        }

        // Read config source info (diagnosis/preset/manual)
        var configSource = window.configSource || {};
        var sourceType = configSource.type || 'manual_adjustment';
        var presetName = configSource.presetName || 'none';
        var prescriptionMethod = configSource.prescriptionMethod || 'unknown';
        var audiogram = configSource.audiogram || new Array(12).fill(0);
        var wasModified = configSource.modified ? 'true' : 'false';

        // Format audiogram as comma-separated values
        var audiogramStr = '';
        for (var j = 0; j < 12; j++) {
            if (j > 0) audiogramStr += ', ';
            audiogramStr += (audiogram[j] || 0).toFixed(0);
        }

        var lines = [
            '% ==========================================================================',
            '% DSP Configuration — Realtime Recording',
            '% Simulador DSP Audifono Digital V2',
            '% Generated: ' + timestamp,
            '% ==========================================================================',
            '',
            '% --- Test/Diagnosis Info ---',
            "config_source_type = '" + sourceType + "';  % clinical_diagnosis_preset | audiogram_preset | manual_adjustment | mixed",
            "preset_name = '" + presetName + "';",
            "prescription_method = '" + prescriptionMethod + "';  % halfGain | nalNL2",
            "user_modified_after_preset = " + wasModified + ";",
            '',
            '% --- Audiogram (dB HL por frecuencia) ---',
            'audiogram_dBHL = [' + audiogramStr + '];',
            'audiogram_frequencies = [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000];',
            '',
            '% --- DSP Pipeline Parameters ---',
            'fs = ' + sampleRate + ';',
            'eq_gains = [' + eqGainsStr + '];',
            'eq_frequencies = [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000];',
            'wdrc_ratio = ' + Number(wdrcRatio).toFixed(2) + ';',
            'wdrc_kneepoint = ' + Number(wdrcKneepoint).toFixed(1) + ';',
            'wdrc_attack_ms = ' + Number(wdrcAttackMs).toFixed(1) + ';',
            'wdrc_release_ms = ' + Number(wdrcReleaseMs).toFixed(1) + ';',
            'expansion_kneepoint = 35.0;  % dB SPL — expansion kneepoint (hardware constant)',
            'expansion_ratio = 2.0;  % input:output expansion ratio',
            'mpo_threshold = ' + Number(mpoThreshold).toFixed(1) + ';',
            'master_volume_db = ' + Number(masterVolumeDb).toFixed(1) + ';',
            'duration_seconds = ' + Number(durationSeconds).toFixed(3) + ';',
            '',
            '% --- Load Audio Files ---',
            "[input_signal, fs_in] = audioread('realtime_input.wav');",
            "[output_signal, fs_out] = audioread('realtime_output.wav');",
            '',
            '% --- Display Test Summary ---',
            "fprintf('\\n=== Resumen del Test ===\\n');",
            "fprintf('Diagnostico/Preset: %s\\n', preset_name);",
            "fprintf('Tipo de config: %s\\n', config_source_type);",
            "fprintf('Metodo prescripcion: %s\\n', prescription_method);",
            "fprintf('Modificado por usuario: %s\\n', mat2str(user_modified_after_preset));",
            "fprintf('Sample rate: %d Hz\\n', fs);",
            "fprintf('Duracion: %.2f seg\\n', duration_seconds);",
            "fprintf('WDRC ratio: %.2f, kneepoint: %.1f dB\\n', wdrc_ratio, wdrc_kneepoint);",
            "fprintf('MPO threshold: %.1f dB\\n', mpo_threshold);",
            "fprintf('Master volume: %.1f dB\\n', master_volume_db);",
            "fprintf('EQ gains (dB): '); fprintf('%.0f ', eq_gains); fprintf('\\n');",
            "fprintf('Audiograma (dB HL): '); fprintf('%.0f ', audiogram_dBHL); fprintf('\\n');",
            "fprintf('========================\\n\\n');",
            ''
        ];

        return lines.join('\n');
    }

    // =========================================================================
    // RealtimeRecorder Module
    // =========================================================================

    var RealtimeRecorder = {

        /** @type {boolean} Whether recording is in progress */
        _recording: false,

        /** @type {number|null} Recording start timestamp (ms) */
        _startTime: null,

        /** @type {number|null} Timer ID for duration display */
        _durationTimer: null,

        /** @type {function|null} Callback for duration updates */
        onDurationUpdate: null,

        /** @type {function|null} Callback when recording stops and files are ready */
        onRecordingComplete: null,

        /** @type {function|null} Original worklet message handler (to chain) */
        _originalOnMessage: null,

        /** @type {function|null} Resolve function for pending stop promise */
        _pendingResolve: null,

        // =====================================================================
        // Public API
        // =====================================================================

        /**
         * Check if recording is currently active.
         * @returns {boolean}
         */
        isRecording: function () {
            return this._recording;
        },

        /**
         * Start recording input and output audio from the active realtime session.
         * Requires RealtimeModule to be in 'active' state.
         * @returns {boolean} true if recording started successfully
         */
        startRecording: function () {
            if (this._recording) return false;

            // Verify realtime module is active
            if (!window.RealtimeModule || window.RealtimeModule.state !== 'active') {
                return false;
            }

            var workletNode = window.RealtimeModule.workletNode;
            if (!workletNode || !workletNode.port) {
                return false;
            }

            this._recording = true;
            this._startTime = Date.now();

            // Hook into worklet message port to intercept recordingData
            this._hookWorkletPort(workletNode);

            // Send start recording message to worklet
            workletNode.port.postMessage({ type: 'startRecording' });

            // Start duration timer
            this._startDurationTimer();

            return true;
        },

        /**
         * Stop recording and trigger download of WAV files + config.m.
         * Returns a promise that resolves when files are downloaded.
         * @returns {Promise<void>}
         */
        stopRecording: function () {
            var self = this;

            if (!this._recording) {
                return Promise.resolve();
            }

            // Verify realtime module and worklet are still available
            if (!window.RealtimeModule || !window.RealtimeModule.workletNode) {
                this._cleanup();
                return Promise.resolve();
            }

            var workletNode = window.RealtimeModule.workletNode;

            return new Promise(function (resolve) {
                self._pendingResolve = resolve;

                // Send stop recording message to worklet
                workletNode.port.postMessage({ type: 'stopRecording' });

                // Timeout: if no response in 5 seconds, resolve anyway
                setTimeout(function () {
                    if (self._pendingResolve) {
                        self._pendingResolve = null;
                        self._cleanup();
                        resolve();
                    }
                }, 5000);
            });
        },

        /**
         * Get elapsed recording time in seconds.
         * @returns {number} Seconds elapsed since recording started, or 0
         */
        getElapsedSeconds: function () {
            if (!this._recording || !this._startTime) return 0;
            return (Date.now() - this._startTime) / 1000;
        },

        // =====================================================================
        // Internal
        // =====================================================================

        /**
         * Hook into the worklet node's message port to intercept recordingData messages.
         * Chains with the existing onmessage handler.
         * @param {AudioWorkletNode} workletNode
         */
        _hookWorkletPort: function (workletNode) {
            var self = this;
            var port = workletNode.port;

            // Store original handler reference
            this._originalOnMessage = port.onmessage;

            // Replace with interceptor
            port.onmessage = function (event) {
                var data = event.data;

                if (data && data.type === 'recordingData') {
                    // Handle recording data
                    self._handleRecordingData(data.inputSamples, data.outputSamples);
                    return;
                }

                // Chain to original handler
                if (self._originalOnMessage) {
                    self._originalOnMessage.call(port, event);
                }
            };
        },

        /**
         * Restore the original worklet port message handler.
         */
        _unhookWorkletPort: function () {
            if (!window.RealtimeModule || !window.RealtimeModule.workletNode) return;
            var port = window.RealtimeModule.workletNode.port;
            if (this._originalOnMessage) {
                port.onmessage = this._originalOnMessage;
                this._originalOnMessage = null;
            }
        },

        /**
         * Handle received recording data from the worklet.
         * Encodes WAV files and generates config.m, then triggers downloads.
         * @param {Float32Array} inputSamples
         * @param {Float32Array} outputSamples
         */
        _handleRecordingData: function (inputSamples, outputSamples) {
            var sampleRate = 48000;
            if (window.RealtimeModule && window.RealtimeModule.audioContext) {
                sampleRate = window.RealtimeModule.audioContext.sampleRate;
            }

            var durationSeconds = inputSamples.length / sampleRate;

            // Calculate metrics from recorded audio
            this._updateReportWithMetrics(inputSamples, outputSamples, sampleRate, durationSeconds);

            // Encode WAV files
            var inputWav = encodeWav(inputSamples, sampleRate);
            var outputWav = encodeWav(outputSamples, sampleRate);

            // Generate config.m
            var configM = generateConfigM(sampleRate, durationSeconds);

            // Download all 3 files with small delays to avoid browser blocking
            downloadFile(inputWav, 'realtime_input.wav');
            setTimeout(function () {
                downloadFile(outputWav, 'realtime_output.wav');
            }, 300);
            setTimeout(function () {
                downloadFile(configM, 'realtime_config.m', 'text/plain');
            }, 600);

            // Notify completion
            if (this.onRecordingComplete) {
                this.onRecordingComplete(durationSeconds);
            }

            // Resolve pending promise
            if (this._pendingResolve) {
                var resolve = this._pendingResolve;
                this._pendingResolve = null;
                resolve();
            }

            // Cleanup
            this._cleanup();
        },

        /**
         * Calculate metrics from recorded input/output and display in report section.
         */
        _updateReportWithMetrics: function (inputSamples, outputSamples, sampleRate, duration) {
            var container = document.getElementById('report-content');
            if (!container) return;

            // Calculate RMS
            var inputSumSq = 0, outputSumSq = 0;
            var inputPeak = 0, outputPeak = 0;
            var N = inputSamples.length;

            for (var i = 0; i < N; i++) {
                var inAbs = Math.abs(inputSamples[i]);
                var outAbs = Math.abs(outputSamples[i]);
                inputSumSq += inputSamples[i] * inputSamples[i];
                outputSumSq += outputSamples[i] * outputSamples[i];
                if (inAbs > inputPeak) inputPeak = inAbs;
                if (outAbs > outputPeak) outputPeak = outAbs;
            }

            var inputRms = Math.sqrt(inputSumSq / N);
            var outputRms = Math.sqrt(outputSumSq / N);

            var inputRmsDb = inputRms > 1e-10 ? (20 * Math.log10(inputRms)).toFixed(1) : '-inf';
            var outputRmsDb = outputRms > 1e-10 ? (20 * Math.log10(outputRms)).toFixed(1) : '-inf';
            var gainDb = (inputRms > 1e-10 && outputRms > 1e-10) ?
                (20 * Math.log10(outputRms / inputRms)).toFixed(1) : 'N/A';

            // Determine WDRC region
            var offset = 76; // realtime uses 76 in _buildProcessorOptions
            var inputSPL = inputRms > 1e-10 ? (20 * Math.log10(inputRms) + offset) : 0;
            var expansionKnee = window.currentWdrcExpansionKnee || 35;
            var compressionKnee = window.currentWdrcKneepoint || 50;
            var wdrcRegion = 'LINEAL';
            if (inputSPL < expansionKnee) wdrcRegion = 'EXPANSIÓN (atenuando)';
            else if (inputSPL > compressionKnee) wdrcRegion = 'COMPRESIÓN (reduciendo)';

            // Read config source
            var configSource = window.configSource || {};
            var presetName = configSource.presetName || 'manual';
            var sourceType = configSource.type || 'manual_adjustment';
            var prescMethod = configSource.prescriptionMethod || 'N/A';
            var audiogram = configSource.audiogram || [];
            var eqGains = window.currentEqGains || [];
            var wdrcRatio = window.currentWdrcRatio || 2.0;
            var mpoThreshold = window.currentMpoThreshold || 110;
            var masterVolumeDb = window.currentMasterVolumeDb || 0;

            // Bypass state
            var bypassActive = (window.RealtimeModule && window.RealtimeModule.bypassActive) ? 'ON' : 'OFF';

            // Safety attenuation
            var safetyGain = 1.0;
            if (window.RealtimeModule && window.RealtimeModule.safetyGainNode) {
                safetyGain = window.RealtimeModule.safetyGainNode.gain.value;
            }
            var safetyDb = safetyGain < 0.99 ? (20 * Math.log10(safetyGain)).toFixed(0) : '0';
            var outputDevice = safetyGain < 0.5 ? 'PARLANTE (atenuado)' : 'AURICULARES';

            var timestamp = new Date().toISOString().replace('T', ' ').substring(0, 19);

            var lines = [
                '═══════════════════════════════════════════════════════════════',
                '  REPORTE DSP — Audífono Digital V2 (Modo Realtime)',
                '═══════════════════════════════════════════════════════════════',
                '  Timestamp:           ' + timestamp,
                '  Modo:                REALTIME (micrófono)',
                '  Bypass:              ' + bypassActive,
                '  Dispositivo salida:  ' + outputDevice,
                '  Safety Attenuation:  ' + safetyDb + ' dB',
                '',
                '  ─── Grabación ───',
                '',
                '  Duración:            ' + duration.toFixed(2) + 's',
                '  Sample Rate:         ' + sampleRate + ' Hz',
                '  Muestras:            ' + N.toLocaleString(),
                '',
                '  ─── Preset / Diagnóstico ───',
                '',
                '  Tipo config:         ' + sourceType,
                '  Preset:              ' + presetName,
                '  Prescripción:        ' + prescMethod,
                '  Audiograma (dB HL):  [' + audiogram.join(', ') + ']',
                '',
                '  ─── Métricas ───',
                '',
                '  Input Peak:          ' + (inputPeak * 100).toFixed(2) + '% FS',
                '  Output Peak:         ' + (outputPeak * 100).toFixed(2) + '% FS',
                '  Input RMS:           ' + inputRmsDb + ' dBFS',
                '  Input Level (SPL):   ' + inputSPL.toFixed(1) + ' dB SPL (offset ' + offset + ')',
                '  Output RMS:          ' + outputRmsDb + ' dBFS',
                '  Ganancia Efectiva:   ' + gainDb + ' dB',
                '',
                '  ─── Estado WDRC ───',
                '',
                '  Región activa:       ' + wdrcRegion,
                '  Expansion Knee:      ' + expansionKnee + ' dB SPL (ER=' + (window.currentWdrcExpansionRatio || 2.0) + ':1)',
                '  Compression Knee:    ' + compressionKnee + ' dB SPL (CR=' + wdrcRatio + ':1)',
                '  Attack:              ' + (window.currentWdrcAttackMs || 5.0) + ' ms',
                '  Release:             ' + (window.currentWdrcReleaseMs || 100.0) + ' ms',
                '',
                '  ─── Configuración Completa ───',
                '',
                '  EQ Gains (dB):       [' + eqGains.join(', ') + ']',
                '  Noise Reduction:     Level ' + (window.currentNrLevel || 0),
                '  Feedback Cancel:     ' + (window.currentFeedbackEnabled ? 'ON' : 'OFF'),
                '  MPO Threshold:       ' + mpoThreshold + ' dB SPL',
                '  Master Volume:       ' + masterVolumeDb + ' dB',
                '  Calibración Offset:  ' + offset + ' dB (realtime)',
                '',
                '  ─── Compliance ───',
                '',
                '  Sin clipping:        ' + (outputPeak <= 0.99 ? '✓ PASS' : '✗ CLIP (' + (outputPeak * 100).toFixed(1) + '%)'),
                '  Ganancia > 0 dB:     ' + (parseFloat(gainDb) > 0 ? '✓ PASS (+' + gainDb + ' dB)' : (bypassActive === 'ON' ? '— BYPASS' : '✗ FAIL (' + gainDb + ' dB)')),
                '',
                '  ─── Evaluación Clínica ───',
                ''
            ];

            // Evaluación de ruido: medir RMS de los segmentos más silenciosos del input
            // (aproximación: si output RMS en silencio > -40 dBFS, hay ruido amplificado)
            var silenceThreshold = 0.001; // -60 dBFS
            var silentOutputSumSq = 0;
            var silentSamples = 0;
            var blockLen = 128;
            for (var blk = 0; blk < Math.floor(N / blockLen); blk++) {
                var blkStart = blk * blockLen;
                var blkInputRms = 0;
                for (var s = blkStart; s < blkStart + blockLen; s++) {
                    blkInputRms += inputSamples[s] * inputSamples[s];
                }
                blkInputRms = Math.sqrt(blkInputRms / blockLen);
                if (blkInputRms < silenceThreshold) {
                    for (var s2 = blkStart; s2 < blkStart + blockLen; s2++) {
                        silentOutputSumSq += outputSamples[s2] * outputSamples[s2];
                        silentSamples++;
                    }
                }
            }
            var silenceOutputDb = -100;
            if (silentSamples > 0) {
                var silRms = Math.sqrt(silentOutputSumSq / silentSamples);
                silenceOutputDb = silRms > 1e-10 ? 20 * Math.log10(silRms) : -100;
            }
            var noiseOk = silenceOutputDb < -40;
            if (silentSamples > 0) {
                lines.push('  Ruido de fondo:      ' + silenceOutputDb.toFixed(1) + ' dBFS ' + (noiseOk ? '✓ OK (< -40 dBFS)' : '✗ ALTO — ruido amplificado'));
            } else {
                lines.push('  Ruido de fondo:      — (sin segmentos silenciosos detectados)');
            }

            // SNR estimado
            var snrEst = parseFloat(outputRmsDb) - silenceOutputDb;
            var snrOk = snrEst > 15;
            if (silentSamples > 0) {
                lines.push('  SNR estimado:        ' + snrEst.toFixed(1) + ' dB ' + (snrOk ? '✓ OK (> 15 dB)' : '⚠ BAJO — señal poco clara'));
            } else {
                lines.push('  SNR estimado:        — (no se pudo calcular)');
            }

            // Amplificación
            var gainNum = parseFloat(gainDb);
            var maxEq = 0;
            for (var eg = 0; eg < eqGains.length; eg++) {
                if (eqGains[eg] > maxEq) maxEq = eqGains[eg];
            }
            if (bypassActive === 'ON') {
                lines.push('  Amplificación:       — BYPASS activo (sin procesamiento)');
            } else if (gainNum > 0) {
                lines.push('  Amplificación:       ✓ Output > Input (+' + gainDb + ' dB)');
            } else if (maxEq === 0) {
                lines.push('  Amplificación:       — N/A (EQ en 0 dB)');
            } else {
                lines.push('  Amplificación:       ✗ FALLA — Output ≤ Input (' + gainDb + ' dB)');
            }

            // Seguridad auditiva
            var outPeakSPL = outputPeak > 0 ? 20 * Math.log10(outputPeak) + 120 : 0;
            var safeOk = outPeakSPL < mpoThreshold;
            lines.push('  Seguridad auditiva:  Peak ' + outPeakSPL.toFixed(0) + ' dB SPL ' + (safeOk ? '✓ OK (< MPO ' + mpoThreshold + ')' : '✗ EXCEDE MPO'));

            // Resumen
            var allOk = noiseOk && snrOk && (gainNum > 0 || bypassActive === 'ON' || maxEq === 0) && safeOk && outputPeak <= 0.99;
            lines.push('');
            lines.push('  ═══ RESULTADO: ' + (allOk ? '✓ APROBADO — Procesamiento clínicamente correcto' : '⚠ REVISAR — Ver items marcados con ✗ o ⚠') + ' ═══');
            lines.push('');
            lines.push('═══════════════════════════════════════════════════════════════');

            container.innerHTML = '<pre>' + lines.join('\n') + '</pre>';
        },

        /**
         * Start the duration update timer (fires every 100ms).
         */
        _startDurationTimer: function () {
            var self = this;
            this._durationTimer = setInterval(function () {
                if (!self._recording) {
                    clearInterval(self._durationTimer);
                    self._durationTimer = null;
                    return;
                }
                var elapsed = self.getElapsedSeconds();
                if (self.onDurationUpdate) {
                    self.onDurationUpdate(elapsed);
                }
                // Auto-stop at 60 seconds (safety, worklet also enforces this)
                if (elapsed >= 60) {
                    self.stopRecording();
                }
            }, 100);
        },

        /**
         * Clean up recording state and restore worklet port handler.
         */
        _cleanup: function () {
            this._recording = false;
            this._startTime = null;

            if (this._durationTimer) {
                clearInterval(this._durationTimer);
                this._durationTimer = null;
            }

            this._unhookWorkletPort();
        }
    };

    // =========================================================================
    // Expose globally
    // =========================================================================
    window.RealtimeRecorder = RealtimeRecorder;

})();
