/**
 * LevelMeter — Visual audio level indicator for the Realtime Hearing Aid Simulator.
 * Shows input (microphone) and output (processed) levels as horizontal bars with dB scale.
 * 
 * Features:
 * - RMS to dB conversion with -60 dB floor
 * - Smooth visual decay at 20 dB/sec
 * - Clipping indicator (red) when output > -3 dB, held for 300ms
 * - ~15 fps rendering via requestAnimationFrame with 64ms throttle
 * 
 * Usage:
 *   LevelMeter.init(document.getElementById('level-meter-container'));
 *   LevelMeter.update(inputRms, outputRms);  // called from worklet messages
 *   LevelMeter.reset();
 *   LevelMeter.destroy();
 * 
 * @global
 */
var LevelMeter = (function () {
    'use strict';

    // --- Constants ---
    var DB_MIN = -60;
    var DB_MAX = 0;
    var CLIP_THRESHOLD_DB = -3;
    var DECAY_RATE_DB_PER_SEC = 20;
    var UPDATE_INTERVAL_MS = 64;
    var CLIP_HOLD_MS = 300;

    // --- State ---
    var inputLevelDb = DB_MIN;
    var outputLevelDb = DB_MIN;
    var displayInputDb = DB_MIN;
    var displayOutputDb = DB_MIN;
    var isClipping = false;
    var clipHoldTimer = null;
    var animationFrameId = null;
    var lastRenderTime = 0;
    var lastUpdateTime = 0;
    var containerEl = null;

    // --- DOM references ---
    var inputBarEl = null;
    var outputBarEl = null;
    var inputValueEl = null;
    var outputValueEl = null;
    var rootEl = null;

    // =========================================================================
    // Public API
    // =========================================================================

    /**
     * Initialize the level meter, creating DOM elements inside the given container.
     * @param {HTMLElement} container - Parent element to render into
     */
    function init(container) {
        if (!container) return;
        containerEl = container;

        // Create root wrapper
        rootEl = document.createElement('div');
        rootEl.className = 'level-meter';
        rootEl.style.cssText = 'display:flex;flex-direction:column;gap:8px;padding:12px 0;';

        // Input row
        var inputRow = _createRow('Entrada');
        inputBarEl = inputRow.bar;
        inputValueEl = inputRow.valueEl;
        rootEl.appendChild(inputRow.row);

        // Output row
        var outputRow = _createRow('Salida');
        outputBarEl = outputRow.bar;
        outputValueEl = outputRow.valueEl;
        rootEl.appendChild(outputRow.row);

        containerEl.appendChild(rootEl);

        // Reset state
        inputLevelDb = DB_MIN;
        outputLevelDb = DB_MIN;
        displayInputDb = DB_MIN;
        displayOutputDb = DB_MIN;
        isClipping = false;
        lastUpdateTime = performance.now();
        lastRenderTime = 0;

        _startAnimation();
    }

    /**
     * Receive raw RMS values from the audio worklet, convert to dB, apply decay, detect clipping.
     * @param {number} inputRms - Linear RMS of input signal (0.0 to 1.0+)
     * @param {number} outputRms - Linear RMS of output signal (0.0 to 1.0+)
     */
    function update(inputRms, outputRms) {
        inputLevelDb = _rmsToDb(inputRms);
        outputLevelDb = _rmsToDb(outputRms);

        // Clipping detection on output
        if (outputLevelDb > CLIP_THRESHOLD_DB) {
            _setClipping(true);
        }
    }

    /**
     * Reset both bars to minimum (-60 dB), clear clipping state, stop animation.
     */
    function reset() {
        inputLevelDb = DB_MIN;
        outputLevelDb = DB_MIN;
        displayInputDb = DB_MIN;
        displayOutputDb = DB_MIN;
        _setClipping(false);

        if (clipHoldTimer !== null) {
            clearTimeout(clipHoldTimer);
            clipHoldTimer = null;
        }

        _stopAnimation();

        // Immediately render at minimum
        if (inputBarEl) {
            inputBarEl.style.width = '0%';
            inputBarEl.style.backgroundColor = 'var(--accent)';
        }
        if (outputBarEl) {
            outputBarEl.style.width = '0%';
            outputBarEl.style.backgroundColor = 'var(--accent)';
        }
        if (inputValueEl) inputValueEl.textContent = '-∞ dB';
        if (outputValueEl) outputValueEl.textContent = '-∞ dB';
    }

    /**
     * Cancel animation frame, remove DOM elements, clean up.
     */
    function destroy() {
        _stopAnimation();

        if (clipHoldTimer !== null) {
            clearTimeout(clipHoldTimer);
            clipHoldTimer = null;
        }

        if (rootEl && rootEl.parentNode) {
            rootEl.parentNode.removeChild(rootEl);
        }

        // Null references
        inputBarEl = null;
        outputBarEl = null;
        inputValueEl = null;
        outputValueEl = null;
        rootEl = null;
        containerEl = null;
    }

    // =========================================================================
    // Internal methods
    // =========================================================================

    /**
     * Convert linear RMS value to dB. Clamps to DB_MIN (-60) for very small values.
     * @param {number} rms - Linear RMS value (0.0 to 1.0+)
     * @returns {number} dB value, clamped to [-60, 0+]
     */
    function _rmsToDb(rms) {
        if (rms <= 0) return DB_MIN;
        var db = 20 * Math.log10(rms);
        return db < DB_MIN ? DB_MIN : db;
    }

    /**
     * Map dB value to bar width percentage (0 to 100).
     * -60 dB → 0%, 0 dB → 100%
     * @param {number} db - dB value
     * @returns {number} Width percentage (0-100)
     */
    function _dbToBarWidth(db) {
        if (db <= DB_MIN) return 0;
        if (db >= DB_MAX) return 100;
        return ((db - DB_MIN) / (DB_MAX - DB_MIN)) * 100;
    }

    /**
     * Apply smooth decay when signal decreases. Decay rate: 20 dB/sec.
     * When signal increases, jump immediately to the new level.
     * @param {number} currentDb - Currently displayed dB value
     * @param {number} targetDb - Target dB value from latest measurement
     * @param {number} deltaTime - Time elapsed in seconds
     * @returns {number} New display dB value
     */
    function _applyDecay(currentDb, targetDb, deltaTime) {
        if (targetDb >= currentDb) {
            // Signal increasing: jump immediately
            return targetDb;
        }
        // Signal decreasing: decay at DECAY_RATE_DB_PER_SEC
        var decayed = currentDb - (DECAY_RATE_DB_PER_SEC * deltaTime);
        // Don't decay below the target or below DB_MIN
        if (decayed < targetDb) return targetDb;
        if (decayed < DB_MIN) return DB_MIN;
        return decayed;
    }

    /**
     * Render loop: update bar widths and colors. Throttled to ~15 fps (64ms interval).
     * Called via requestAnimationFrame.
     * @param {number} timestamp - DOMHighResTimeStamp from rAF
     */
    function _render(timestamp) {
        animationFrameId = requestAnimationFrame(_render);

        // Throttle to ~15 fps
        if (timestamp - lastRenderTime < UPDATE_INTERVAL_MS) return;

        var now = timestamp;
        var deltaTime = (now - lastRenderTime) / 1000;
        // Cap deltaTime to avoid huge jumps on tab switch
        if (deltaTime > 0.5) deltaTime = 0.5;
        lastRenderTime = now;

        // Apply decay
        displayInputDb = _applyDecay(displayInputDb, inputLevelDb, deltaTime);
        displayOutputDb = _applyDecay(displayOutputDb, outputLevelDb, deltaTime);

        // Update bar widths
        var inputWidth = _dbToBarWidth(displayInputDb);
        var outputWidth = _dbToBarWidth(displayOutputDb);

        if (inputBarEl) {
            inputBarEl.style.width = inputWidth + '%';
            inputBarEl.style.backgroundColor = 'var(--accent)';
        }

        if (outputBarEl) {
            outputBarEl.style.width = outputWidth + '%';
            outputBarEl.style.backgroundColor = isClipping ? '#ff4444' : 'var(--accent)';
        }

        // Update dB text values
        if (inputValueEl) {
            inputValueEl.textContent = displayInputDb <= DB_MIN ? '-∞ dB' : displayInputDb.toFixed(1) + ' dB';
        }
        if (outputValueEl) {
            outputValueEl.textContent = displayOutputDb <= DB_MIN ? '-∞ dB' : displayOutputDb.toFixed(1) + ' dB';
        }

        // Check if clipping should be released (output dropped below threshold)
        if (isClipping && outputLevelDb <= CLIP_THRESHOLD_DB && clipHoldTimer === null) {
            clipHoldTimer = setTimeout(function () {
                _setClipping(false);
                clipHoldTimer = null;
            }, CLIP_HOLD_MS);
        }
    }

    /**
     * Start the animation loop.
     */
    function _startAnimation() {
        if (animationFrameId !== null) return;
        lastRenderTime = performance.now();
        animationFrameId = requestAnimationFrame(_render);
    }

    /**
     * Stop the animation loop.
     */
    function _stopAnimation() {
        if (animationFrameId !== null) {
            cancelAnimationFrame(animationFrameId);
            animationFrameId = null;
        }
    }

    /**
     * Set clipping state. When turning on, cancel any pending hold timer.
     * @param {boolean} clipping
     */
    function _setClipping(clipping) {
        if (clipping) {
            isClipping = true;
            // Cancel any pending release timer since we're clipping again
            if (clipHoldTimer !== null) {
                clearTimeout(clipHoldTimer);
                clipHoldTimer = null;
            }
        } else {
            isClipping = false;
        }
    }

    /**
     * Create a single meter row (label + bar container + dB value).
     * @param {string} label - Row label text ("Entrada" or "Salida")
     * @returns {{row: HTMLElement, bar: HTMLElement, valueEl: HTMLElement}}
     */
    function _createRow(label) {
        var row = document.createElement('div');
        row.style.cssText = 'display:flex;align-items:center;gap:10px;';

        // Label
        var labelEl = document.createElement('span');
        labelEl.textContent = label;
        labelEl.style.cssText = 'font-size:0.8rem;color:var(--text-secondary);min-width:55px;';
        row.appendChild(labelEl);

        // Bar container
        var barContainer = document.createElement('div');
        barContainer.style.cssText = 'flex:1;height:14px;background:var(--bg-input);border-radius:7px;border:1px solid var(--border);overflow:hidden;position:relative;';

        // Filled bar
        var bar = document.createElement('div');
        bar.style.cssText = 'height:100%;width:0%;background-color:var(--accent);border-radius:7px;transition:none;';
        barContainer.appendChild(bar);

        // dB scale markers (optional visual reference)
        var scaleMarkers = document.createElement('div');
        scaleMarkers.style.cssText = 'position:absolute;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;pointer-events:none;';
        // Add -3 dB marker (clipping threshold)
        var clipMarker = document.createElement('div');
        clipMarker.style.cssText = 'position:absolute;left:95%;top:0;bottom:0;width:1px;background:rgba(255,68,68,0.4);';
        scaleMarkers.appendChild(clipMarker);
        barContainer.appendChild(scaleMarkers);

        row.appendChild(barContainer);

        // dB value text
        var valueEl = document.createElement('span');
        valueEl.textContent = '-∞ dB';
        valueEl.style.cssText = 'font-size:0.75rem;color:var(--text-secondary);min-width:50px;text-align:right;font-family:monospace;';
        row.appendChild(valueEl);

        return { row: row, bar: bar, valueEl: valueEl };
    }

    // =========================================================================
    // Expose as global object
    // =========================================================================

    return {
        // Constants (exposed for testing)
        DB_MIN: DB_MIN,
        DB_MAX: DB_MAX,
        CLIP_THRESHOLD_DB: CLIP_THRESHOLD_DB,
        DECAY_RATE_DB_PER_SEC: DECAY_RATE_DB_PER_SEC,
        UPDATE_INTERVAL_MS: UPDATE_INTERVAL_MS,
        CLIP_HOLD_MS: CLIP_HOLD_MS,

        // State getters (for testing/debugging)
        get inputLevelDb() { return inputLevelDb; },
        get outputLevelDb() { return outputLevelDb; },
        get displayInputDb() { return displayInputDb; },
        get displayOutputDb() { return displayOutputDb; },
        get isClipping() { return isClipping; },
        get animationFrameId() { return animationFrameId; },

        // Public API
        init: init,
        update: update,
        reset: reset,
        destroy: destroy,

        // Internal methods (exposed for testing)
        _rmsToDb: _rmsToDb,
        _dbToBarWidth: _dbToBarWidth,
        _applyDecay: _applyDecay,
        _render: _render,
        _startAnimation: _startAnimation,
        _stopAnimation: _stopAnimation
    };
})();

// Attach to window for global access
window.LevelMeter = LevelMeter;
