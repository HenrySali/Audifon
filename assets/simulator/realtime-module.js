/**
 * =============================================================================
 * RealtimeModule — Orchestrator for Realtime Hearing Aid Simulation
 *
 * Manages the lifecycle of realtime audio processing:
 * - Microphone capture via getUserMedia
 * - AudioWorklet-based DSP processing (DspWorkletProcessor)
 * - Safety attenuation for speaker output
 * - State machine: idle → requesting → active → error
 *
 * Audio Graph:
 *   getUserMedia → MediaStreamSourceNode → AudioWorkletNode → GainNode (safety) → destination
 *
 * Loaded via <script> tag. Exposes window.RealtimeModule.
 * =============================================================================
 */

'use strict';

(function () {

    /**
     * @namespace RealtimeModule
     * Manages the realtime hearing aid simulation lifecycle.
     */
    var RealtimeModule = {

        // =====================================================================
        // State
        // =====================================================================

        /** @type {'idle'|'requesting'|'active'|'error'} */
        state: 'idle',

        /** @type {boolean} Whether bypass mode is active */
        bypassActive: false,

        /** @type {string|null} Preferred microphone deviceId (null = system default) */
        preferredMicId: null,

        /** @type {AudioContext|null} */
        audioContext: null,

        /** @type {MediaStream|null} */
        mediaStream: null,

        /** @type {MediaStreamAudioSourceNode|null} */
        sourceNode: null,

        /** @type {AudioWorkletNode|null} */
        workletNode: null,

        /** @type {GainNode|null} Safety attenuation gain node */
        safetyGainNode: null,

        /** @type {number} Number of AudioContext resume attempts */
        _resumeAttempts: 0,

        /** @type {number} Maximum resume attempts before giving up */
        _maxResumeAttempts: 3,

        /** @type {boolean} Whether event listeners have been registered */
        _listenersRegistered: false,

        /** @type {boolean} Whether destroy has been called */
        _destroyed: false,

        /** @type {boolean} Whether devicechange listener has been registered */
        _deviceChangeRegistered: false,

        /** @type {number|null} Timeout ID for device disconnect handling */
        _disconnectTimeout: null,

        // =====================================================================
        // Callbacks (set by integration layer)
        // =====================================================================

        /** @type {function(number, number)|null} Called with (inputRms, outputRms) */
        onLevels: null,

        /** @type {function(string)|null} Called with new state name */
        onStateChange: null,

        /** @type {function(string)|null} Called with error message */
        onError: null,

        /** @type {function(number)|null} Called with consecutive overload count */
        onOverload: null,

        // =====================================================================
        // Public API
        // =====================================================================

        /**
         * Start realtime processing.
         * Requests microphone, creates AudioContext, loads worklet, connects graph.
         * Transitions: idle → requesting → active (or → error on failure).
         */
        async start() {
            // Guard: only start from idle state
            if (this.state !== 'idle') {
                return;
            }

            // Guard: check browser compatibility
            if (!this._checkCompatibility()) {
                return;
            }

            // Mutual exclusion: stop offline playback before starting realtime
            this._notifyOfflineModule('stop');

            this._setState('requesting');
            this._destroyed = false;

            try {
                // 1. Request microphone access with audio processing disabled.
                // Browser AGC/EC/NS interfere with hearing aid WDRC compression
                // by pre-normalizing levels, making calibration unpredictable.
                //
                // If a specific deviceId is set (e.g., to force the phone's built-in mic
                // when BT headphones are connected), use it via 'exact' constraint.
                var audioConstraints = {
                    autoGainControl: false,
                    echoCancellation: false,
                    noiseSuppression: false
                };
                if (this.preferredMicId) {
                    audioConstraints.deviceId = { exact: this.preferredMicId };
                }
                this.mediaStream = await navigator.mediaDevices.getUserMedia({
                    audio: audioConstraints
                });
            } catch (err) {
                var message = 'Error al acceder al micrófono.';
                if (err.name === 'NotAllowedError' || err.name === 'PermissionDeniedError') {
                    message = 'Permiso de micrófono denegado. Por favor, permite el acceso al micrófono para usar el modo tiempo real.';
                } else if (err.name === 'NotFoundError') {
                    message = 'No se encontró un micrófono. Conecta un dispositivo de audio de entrada.';
                } else if (err.name === 'NotReadableError') {
                    message = 'El micrófono está siendo usado por otra aplicación.';
                }
                this._handleError(message);
                return;
            }

            try {
                // 2. Create AudioContext
                var AudioCtx = window.AudioContext || window.webkitAudioContext;
                this.audioContext = new AudioCtx();

                // 3. Handle suspended AudioContext (browser autoplay policy)
                if (this.audioContext.state === 'suspended') {
                    var resumed = await this._tryResume();
                    if (!resumed) {
                        this._releaseMediaStream();
                        this._handleError('El navegador bloqueó el audio. Haz clic en la página e intenta de nuevo.');
                        return;
                    }
                }

                // 4. Load AudioWorklet module
                await this.audioContext.audioWorklet.addModule('dsp-worklet-processor.js');

            } catch (err) {
                // Worklet or AudioContext initialization failed
                this._releaseMediaStream();
                if (this.audioContext) {
                    try { await this.audioContext.close(); } catch (e) { /* ignore */ }
                    this.audioContext = null;
                }
                this._handleError('Error al inicializar el procesamiento de audio: ' + (err.message || err));
                return;
            }

            try {
                // 5. Connect audio graph
                this._connectAudioGraph();
            } catch (err) {
                this._releaseMediaStream();
                if (this.audioContext) {
                    try { await this.audioContext.close(); } catch (e) { /* ignore */ }
                    this.audioContext = null;
                }
                this._handleError('Error al conectar el grafo de audio: ' + (err.message || err));
                return;
            }

            // 6. Detect output device and apply safety attenuation
            this._detectOutputDevice();

            // 7. Register lifecycle event listeners
            this._registerLifecycleListeners();

            // 8. Register device change listener for disconnect detection
            this._registerDeviceChangeListener();

            // Note: final transition to 'active' happens when worklet sends 'ready' message
            // (see _handleWorkletMessage). If worklet is already ready synchronously,
            // we transition here as a fallback.
            // Give worklet 2 seconds to report ready, otherwise transition anyway.
            var self = this;
            this._readyTimeout = setTimeout(function () {
                if (self.state === 'requesting') {
                    self._setState('active');
                }
            }, 2000);
        },

        /**
         * Stop realtime processing.
         * Disconnects nodes, stops MediaStream tracks, closes AudioContext.
         * Transitions: active/requesting → idle.
         */
        stop() {
            if (this.state === 'idle') {
                return;
            }

            // Clear ready timeout if pending
            if (this._readyTimeout) {
                clearTimeout(this._readyTimeout);
                this._readyTimeout = null;
            }

            // Clear disconnect timeout if pending
            if (this._disconnectTimeout) {
                clearTimeout(this._disconnectTimeout);
                this._disconnectTimeout = null;
            }

            // Send stop message to worklet before disconnecting
            if (this.workletNode && this.workletNode.port) {
                try {
                    this.workletNode.port.postMessage({ type: 'stop' });
                } catch (e) { /* ignore if port is closed */ }
            }

            // Disconnect audio graph
            this._disconnectAudioGraph();

            // Stop all MediaStream tracks
            this._releaseMediaStream();

            // Unregister device change listener
            this._unregisterDeviceChangeListener();

            // Close AudioContext
            if (this.audioContext && this.audioContext.state !== 'closed') {
                this.audioContext.close().catch(function () { /* ignore */ });
            }

            // Null references
            this.audioContext = null;
            this.sourceNode = null;
            this.workletNode = null;
            this.safetyGainNode = null;

            // Reset state
            this.bypassActive = false;
            this._resumeAttempts = 0;

            this._setState('idle');
        },

        /**
         * Full cleanup for page unload.
         * Same as stop() but also removes event listeners.
         */
        destroy() {
            this._destroyed = true;
            this.stop();
            this._unregisterLifecycleListeners();
            this._unregisterDeviceChangeListener();
        },

        /**
         * Toggle bypass mode.
         * Sends setBypass message to worklet.
         * Only works when state === 'active'.
         */
        toggleBypass() {
            if (this.state !== 'active') {
                return;
            }

            this.bypassActive = !this.bypassActive;

            if (this.workletNode && this.workletNode.port) {
                this.workletNode.port.postMessage({
                    type: 'setBypass',
                    active: this.bypassActive
                });
            }
        },

        /**
         * Enumerate available audio input devices (microphones).
         * Requires microphone permission to get device labels.
         * @returns {Promise<Array<{deviceId: string, label: string}>>}
         */
        async enumerateMicrophones() {
            if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
                return [];
            }

            // Request temporary permission to get labels
            var tempStream = null;
            try {
                tempStream = await navigator.mediaDevices.getUserMedia({ audio: true });
            } catch (e) {
                // Permission denied — return empty
                return [];
            }

            try {
                var devices = await navigator.mediaDevices.enumerateDevices();
                var mics = [];
                for (var i = 0; i < devices.length; i++) {
                    if (devices[i].kind === 'audioinput') {
                        mics.push({
                            deviceId: devices[i].deviceId,
                            label: devices[i].label || ('Micrófono ' + (mics.length + 1))
                        });
                    }
                }
                return mics;
            } finally {
                // Release temporary stream
                if (tempStream) {
                    tempStream.getTracks().forEach(function (t) { t.stop(); });
                }
            }
        },

        /**
         * Set the preferred microphone by deviceId.
         * Takes effect on next start() call. If currently active, restarts.
         * @param {string|null} deviceId - null for system default
         */
        async setMicrophone(deviceId) {
            this.preferredMicId = deviceId || null;

            // If currently active, restart to apply new mic
            if (this.state === 'active') {
                this.stop();
                // Small delay to allow cleanup
                await new Promise(function (r) { setTimeout(r, 300); });
                this.start();
            }
        },

        /**
         * Send updated DSP parameters to the worklet.
         * @param {Object} config - DSP configuration object
         * @param {number[]} [config.eq_gains] - 12-element array, 0-50 dB per band
         * @param {number} [config.wdrc_ratio] - Compression ratio 1.0-4.0
         * @param {number} [config.wdrc_kneepoint] - Kneepoint in dB SPL (40-80)
         * @param {number} [config.wdrc_attack_ms] - Attack time 1-10 ms
         * @param {number} [config.wdrc_release_ms] - Release time 50-500 ms
         * @param {number} [config.mpo_threshold] - MPO threshold 90-110 dB SPL
         * @param {number} [config.master_volume_db] - Master volume -20 to +10 dB
         */
        updateDspParams(config) {
            if (!config) return;
            if (this.state !== 'active' && this.state !== 'requesting') {
                return;
            }

            if (this.workletNode && this.workletNode.port) {
                this.workletNode.port.postMessage({
                    type: 'updateParams',
                    config: config
                });
            }
        },

        // =====================================================================
        // Internal: Audio Graph
        // =====================================================================

        /**
         * Connect the audio graph:
         * MediaStreamSource → AudioWorkletNode → GainNode (safety) → destination
         */
        _connectAudioGraph() {
            var ctx = this.audioContext;

            // Create source node from microphone stream
            this.sourceNode = ctx.createMediaStreamSource(this.mediaStream);

            // Create AudioWorkletNode with initial DSP config
            var processorOptions = this._buildProcessorOptions();
            this.workletNode = new AudioWorkletNode(ctx, 'dsp-worklet-processor', {
                processorOptions: processorOptions
            });

            // Set up message handling from worklet
            var self = this;
            this.workletNode.port.onmessage = function (event) {
                self._handleWorkletMessage(event);
            };

            // Create safety gain node (default: unity gain, attenuated for speakers)
            this.safetyGainNode = ctx.createGain();
            this.safetyGainNode.gain.value = 1.0;

            // Connect the graph: source → worklet → safety gain → destination
            this.sourceNode.connect(this.workletNode);
            this.workletNode.connect(this.safetyGainNode);
            this.safetyGainNode.connect(ctx.destination);
        },

        /**
         * Disconnect all audio graph nodes safely.
         */
        _disconnectAudioGraph() {
            try {
                if (this.sourceNode) {
                    this.sourceNode.disconnect();
                }
            } catch (e) { /* ignore */ }

            try {
                if (this.workletNode) {
                    this.workletNode.disconnect();
                }
            } catch (e) { /* ignore */ }

            try {
                if (this.safetyGainNode) {
                    this.safetyGainNode.disconnect();
                }
            } catch (e) { /* ignore */ }
        },

        /**
         * Build processorOptions for the AudioWorkletNode constructor.
         * Reads current DSP parameters from the simulator's global state.
         * @returns {Object} processorOptions for DspWorkletProcessor
         */
        _buildProcessorOptions() {
            // Try to read current config from the simulator's global state
            var eqGains = window.currentEqGains || new Array(12).fill(0);
            var wdrcRatio = window.currentWdrcRatio || 2.0;
            var mpoThreshold = window.currentMpoThreshold || 110;
            var masterVolumeDb = window.currentMasterVolumeDb || 0;

            // Also try reading from app.js exposed variables
            if (typeof currentEqGains !== 'undefined') eqGains = currentEqGains;
            if (typeof currentWdrcRatio !== 'undefined') wdrcRatio = currentWdrcRatio;
            if (typeof currentMpoThreshold !== 'undefined') mpoThreshold = currentMpoThreshold;
            if (typeof currentMasterVolumeDb !== 'undefined') masterVolumeDb = currentMasterVolumeDb;

            return {
                eq_gains: Array.isArray(eqGains) ? eqGains.slice() : new Array(12).fill(0),
                wdrc_ratio: wdrcRatio,
                wdrc_kneepoint: 50.0,
                wdrc_attack_ms: 5.0,
                wdrc_release_ms: 100.0,
                wdrc_expansion_knee: 35.0,
                wdrc_expansion_ratio: 2.0,
                mpo_threshold: mpoThreshold,
                master_volume_db: masterVolumeDb,
                // Browser mic calibration: use same offset as WAV (76 dB).
                // Browser mics with OS-level gain deliver levels comparable to WAV files.
                // With offset 76: typical speech at -37 dBFS → 39 dB SPL (WDRC linear region).
                realtime_offset: 76.0,
                sample_rate: this.audioContext ? this.audioContext.sampleRate : 48000
            };
        },

        // =====================================================================
        // Internal: Worklet Message Handling
        // =====================================================================

        /**
         * Handle messages from the DspWorkletProcessor via MessagePort.
         * Routes: 'levels', 'overload', 'ready'
         * @param {MessageEvent} event
         */
        _handleWorkletMessage(event) {
            var data = event.data;
            if (!data || !data.type) return;

            switch (data.type) {
                case 'ready':
                    // Worklet is initialized and ready to process
                    if (this.state === 'requesting') {
                        if (this._readyTimeout) {
                            clearTimeout(this._readyTimeout);
                            this._readyTimeout = null;
                        }
                        this._setState('active');
                    }
                    break;

                case 'levels':
                    // Level meter update: { inputRms, outputRms }
                    if (this.onLevels && this.state === 'active') {
                        this.onLevels(data.inputRms, data.outputRms);
                    }
                    break;

                case 'overload':
                    // CPU budget exceeded: { consecutive }
                    if (this.onOverload) {
                        this.onOverload(data.consecutive);
                    }
                    break;
            }
        },

        // =====================================================================
        // Internal: State Machine
        // =====================================================================

        /**
         * Transition to a new state and notify listeners.
         * @param {'idle'|'requesting'|'active'|'error'} newState
         */
        _setState(newState) {
            var oldState = this.state;
            if (oldState === newState) return;

            this.state = newState;

            // Notify state change callback
            if (this.onStateChange) {
                this.onStateChange(newState);
            }

            // Set global flag for mutual exclusion with offline playback
            window.realtimeActive = (newState === 'active');
        },

        /**
         * Handle an error condition: set error state and notify.
         * @param {string} message - Error message for the user
         */
        _handleError(message) {
            this._setState('error');

            if (this.onError) {
                this.onError(message);
            }

            // Auto-transition back to idle after error is reported
            // (UI layer should acknowledge the error)
            var self = this;
            setTimeout(function () {
                if (self.state === 'error') {
                    self._setState('idle');
                }
            }, 100);
        },

        // =====================================================================
        // Internal: Browser Compatibility & AudioContext Resume
        // =====================================================================

        /**
         * Check browser compatibility for realtime audio.
         * @returns {boolean} true if compatible
         */
        _checkCompatibility() {
            if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                this._handleError('Tu navegador no soporta la captura de audio (getUserMedia). Usa Chrome, Firefox o Edge actualizado.');
                return false;
            }

            if (!window.AudioContext && !window.webkitAudioContext) {
                this._handleError('Tu navegador no soporta AudioContext. Usa Chrome, Firefox o Edge actualizado.');
                return false;
            }

            if (typeof AudioWorkletNode === 'undefined') {
                this._handleError('Tu navegador no soporta AudioWorklet. Usa Chrome 66+, Firefox 76+ o Edge 79+.');
                return false;
            }

            return true;
        },

        /**
         * Try to resume a suspended AudioContext.
         * Retries up to _maxResumeAttempts times.
         * @returns {Promise<boolean>} true if resumed successfully
         */
        async _tryResume() {
            this._resumeAttempts = 0;

            while (this._resumeAttempts < this._maxResumeAttempts) {
                this._resumeAttempts++;
                try {
                    await this.audioContext.resume();
                    if (this.audioContext.state === 'running') {
                        return true;
                    }
                } catch (e) {
                    // resume() failed, try again
                }
                // Small delay between attempts
                await new Promise(function (resolve) { setTimeout(resolve, 200); });
            }

            return false;
        },

        // =====================================================================
        // Internal: Resource Cleanup
        // =====================================================================

        /**
         * Stop all tracks in the MediaStream and null the reference.
         */
        _releaseMediaStream() {
            if (this.mediaStream) {
                this.mediaStream.getTracks().forEach(function (track) {
                    track.stop();
                });
                this.mediaStream = null;
            }
        },

        // =====================================================================
        // Internal: Lifecycle Event Listeners
        // =====================================================================

        /**
         * Register beforeunload and visibilitychange listeners for cleanup.
         */
        _registerLifecycleListeners() {
            if (this._listenersRegistered) return;

            var self = this;

            this._onBeforeUnload = function () {
                self.destroy();
            };

            this._onVisibilityChange = function () {
                if (document.visibilityState === 'hidden' && self.state === 'active') {
                    self.destroy();
                }
            };

            window.addEventListener('beforeunload', this._onBeforeUnload);
            document.addEventListener('visibilitychange', this._onVisibilityChange);

            this._listenersRegistered = true;
        },

        /**
         * Remove lifecycle event listeners.
         */
        _unregisterLifecycleListeners() {
            if (!this._listenersRegistered) return;

            if (this._onBeforeUnload) {
                window.removeEventListener('beforeunload', this._onBeforeUnload);
                this._onBeforeUnload = null;
            }

            if (this._onVisibilityChange) {
                document.removeEventListener('visibilitychange', this._onVisibilityChange);
                this._onVisibilityChange = null;
            }

            this._listenersRegistered = false;
        },

        // =====================================================================
        // Internal: Mutual Exclusion with Offline Playback
        // =====================================================================

        /**
         * Notify the offline module to stop playback before starting realtime.
         * @param {'stop'} action
         */
        _notifyOfflineModule(action) {
            if (action === 'stop' && typeof window.stopOfflinePlayback === 'function') {
                window.stopOfflinePlayback();
            }
        },

        // =====================================================================
        // Internal: Output Device Detection & Safety Attenuation
        // =====================================================================

        /**
         * Detect whether the output device is headphones or speakers.
         * Uses navigator.mediaDevices.enumerateDevices() to check output device labels.
         * If no headphone-type output is found, assumes speakers and applies safety attenuation.
         */
        _detectOutputDevice() {
            var self = this;

            // Check if enumerateDevices is available
            if (!navigator.mediaDevices || typeof navigator.mediaDevices.enumerateDevices !== 'function') {
                // Cannot detect device type — assume speakers for safety
                self._applySafetyAttenuation(true);
                return;
            }

            navigator.mediaDevices.enumerateDevices().then(function (devices) {
                var headphoneDetected = false;

                for (var i = 0; i < devices.length; i++) {
                    var device = devices[i];
                    if (device.kind === 'audiooutput') {
                        var label = (device.label || '').toLowerCase();
                        if (label.indexOf('headphone') !== -1 ||
                            label.indexOf('headset') !== -1 ||
                            label.indexOf('earphone') !== -1 ||
                            label.indexOf('auricular') !== -1) {
                            headphoneDetected = true;
                            break;
                        }
                    }
                }

                // Apply safety attenuation based on detection result
                self._applySafetyAttenuation(!headphoneDetected);
            }).catch(function () {
                // On error, assume speakers for safety
                self._applySafetyAttenuation(true);
            });
        },

        /**
         * Apply or remove safety attenuation on the safetyGainNode.
         * When speakers are detected (isSpeaker=true), attenuate by -20dB (gain = 0.1).
         * When headphones are detected (isSpeaker=false), set unity gain (1.0).
         * @param {boolean} isSpeaker - true if output is speakers, false if headphones
         */
        _applySafetyAttenuation(isSpeaker) {
            if (!this.safetyGainNode) return;

            if (isSpeaker) {
                // -20 dB = 10^(-20/20) = 0.1 linear gain
                this.safetyGainNode.gain.value = 0.1;
            } else {
                // Unity gain (no attenuation) for headphones
                this.safetyGainNode.gain.value = 1.0;
            }
        },

        /**
         * Register a listener for the 'devicechange' event to detect output device
         * disconnection while processing is active.
         */
        _registerDeviceChangeListener() {
            if (this._deviceChangeRegistered) return;

            var self = this;

            this._onDeviceChange = function () {
                // Only act if we are actively processing
                if (self.state !== 'active' && self.state !== 'requesting') {
                    return;
                }

                // Re-detect output device (may have changed to speakers)
                self._detectOutputDevice();

                // Check if output device was disconnected by re-enumerating
                if (!navigator.mediaDevices || typeof navigator.mediaDevices.enumerateDevices !== 'function') {
                    return;
                }

                navigator.mediaDevices.enumerateDevices().then(function (devices) {
                    var hasAudioOutput = false;
                    for (var i = 0; i < devices.length; i++) {
                        if (devices[i].kind === 'audiooutput' && devices[i].deviceId !== '') {
                            hasAudioOutput = true;
                            break;
                        }
                    }

                    // If no audio output devices found, stop processing within 2 seconds
                    if (!hasAudioOutput && (self.state === 'active' || self.state === 'requesting')) {
                        self._handleDeviceDisconnect();
                    }
                }).catch(function () {
                    // On enumeration error during active session, stop for safety
                    if (self.state === 'active' || self.state === 'requesting') {
                        self._handleDeviceDisconnect();
                    }
                });
            };

            navigator.mediaDevices.addEventListener('devicechange', this._onDeviceChange);
            this._deviceChangeRegistered = true;
        },

        /**
         * Unregister the devicechange event listener.
         */
        _unregisterDeviceChangeListener() {
            if (!this._deviceChangeRegistered) return;

            if (this._onDeviceChange && navigator.mediaDevices) {
                navigator.mediaDevices.removeEventListener('devicechange', this._onDeviceChange);
                this._onDeviceChange = null;
            }

            this._deviceChangeRegistered = false;
        },

        /**
         * Handle output device disconnection.
         * Stops processing within 2 seconds and notifies the user via onError callback.
         */
        _handleDeviceDisconnect() {
            var self = this;

            // Stop processing within 2 seconds (use a short timeout to allow any pending audio to flush)
            if (this._disconnectTimeout) {
                clearTimeout(this._disconnectTimeout);
            }

            this._disconnectTimeout = setTimeout(function () {
                self._disconnectTimeout = null;
                if (self.state === 'active' || self.state === 'requesting') {
                    self.stop();
                    // Notify user about device disconnection
                    if (self.onError) {
                        self.onError('Dispositivo de audio de salida desconectado. El procesamiento en tiempo real se ha detenido.');
                    }
                }
            }, 500); // Stop quickly (well within the 2s requirement)
        }
    };

    // =========================================================================
    // Expose globally
    // =========================================================================
    window.RealtimeModule = RealtimeModule;

    // Initialize global flag for mutual exclusion
    if (typeof window.realtimeActive === 'undefined') {
        window.realtimeActive = false;
    }

})();
