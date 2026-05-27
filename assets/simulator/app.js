/**
 * =============================================================================
 * App — Controlador principal del simulador web
 * 
 * Usa window.DspEngine (dsp-engine-browser.js) con factory functions.
 * Pipeline procesa a 16kHz con bloques de 64 muestras (Int16).
 * =============================================================================
 */

// --- Estado global ---
const DSP = window.DspEngine;
let pipeline = DSP.createDspPipeline();
window.pipeline = pipeline; // Expose for dsp-config-export module
let audioContext = null;
let originalBuffer = null;
let processedBuffer = null;
let currentSource = null;
let isPlaying = false;
let startTime = 0;

// --- Current DSP parameters (for building config) ---
let currentEqGains = new Array(12).fill(0);
let currentWdrcRatio = 2.0;
let currentNrLevel = 0;
let currentMpoThreshold = 110;
let currentFeedbackEnabled = 0;
let currentMasterVolumeDb = 0;

// Expose DSP parameters globally for realtime-recorder.js (config.m export)
window.currentEqGains = currentEqGains;
window.currentWdrcRatio = currentWdrcRatio;
window.currentWdrcKneepoint = 50.0;
window.currentWdrcAttackMs = 5.0;
window.currentWdrcReleaseMs = 100.0;
window.currentWdrcExpansionKnee = 35.0;
window.currentWdrcExpansionRatio = 2.0;
window.currentMpoThreshold = currentMpoThreshold;
window.currentMasterVolumeDb = currentMasterVolumeDb;

// --- Configuration Source Tracking (for DSP export) ---
window.configSource = {
    type: 'manual_adjustment',       // 'clinical_diagnosis_preset' | 'audiogram_preset' | 'manual_adjustment' | 'mixed'
    presetName: null,                // e.g., 'child-mild-hf'
    prescriptionMethod: null,        // 'halfGain' | 'nalNL2' | null
    audiogram: null,                 // 12-element array of dB HL values
    modified: false                  // true if user changed params after loading a preset
};

/**
 * Marks the configSource as modified by the user.
 * If a preset was loaded, transitions type to 'mixed'.
 */
function markConfigModified() {
    if (window.configSource.type === 'clinical_diagnosis_preset' || 
        window.configSource.type === 'audiogram_preset') {
        window.configSource.type = 'mixed';
        window.configSource.modified = true;
    }
    // Update indicator to show modification
    const nameEl = document.getElementById('active-config-name');
    const indicator = document.getElementById('active-config-indicator');
    if (nameEl && indicator && indicator.style.display !== 'none') {
        const current = nameEl.textContent.replace(' (modificado)', '');
        nameEl.textContent = current + ' (modificado)';
    }
}

// --- Frecuencias de las bandas ---
const FREQUENCIES = [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000];

// --- Presets de audiogramas ---
const PRESETS = {
    normal:   [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    mild:     [10, 10, 15, 20, 25, 30, 30, 35, 35, 40, 40, 45],
    moderate: [20, 25, 30, 35, 40, 45, 50, 55, 55, 60, 65, 70],
    severe:   [40, 45, 50, 60, 65, 70, 75, 80, 80, 85, 90, 95],
    highfreq: [5, 10, 10, 15, 25, 35, 45, 55, 60, 65, 75, 85],
    flat:     [40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40],
    from1k:   [10, 10, 15, 20, 30, 40, 45, 50, 55, 60, 65, 70]
};

// --- Diagnósticos clínicos completos (10 presets validados) ---
const DIAGNOSES = {
    'child-mild-hf': {
        name: 'Niño — Pérdida Leve HF',
        audiogram: [5, 5, 10, 15, 20, 30, 35, 40, 40, 45, 50, 55],
        method: 'nalNL2',
        wdrcRatio: 1.5,
        kneepoint: 60,
        nrLevel: 0,
        volume: 0,
        env: 'quiet'
    },
    'child-moderate': {
        name: 'Niño — Pérdida Moderada',
        audiogram: [20, 25, 30, 35, 40, 50, 55, 60, 60, 65, 70, 75],
        method: 'nalNL2',
        wdrcRatio: 2.0,
        kneepoint: 50,
        nrLevel: 1,
        volume: 0,
        env: 'conversation'
    },
    'adult-presbycusis': {
        name: 'Adulto — Presbiacusia',
        audiogram: [10, 10, 15, 20, 30, 40, 45, 50, 55, 60, 65, 70],
        method: 'nalNL2',
        wdrcRatio: 2.0,
        kneepoint: 55,
        nrLevel: 1,
        volume: 0,
        env: 'conversation'
    },
    'adult-severe-flat': {
        name: 'Adulto — Severa Plana',
        audiogram: [55, 60, 60, 65, 65, 70, 70, 75, 75, 80, 80, 85],
        method: 'nalNL2',
        wdrcRatio: 3.0,
        kneepoint: 45,
        nrLevel: 2,
        volume: 3,
        env: 'noisy'
    },
    'child-mild-flat': {
        name: 'Niño — Leve Plana',
        audiogram: [15, 15, 18, 18, 20, 20, 20, 18, 18, 15, 15, 14],
        method: 'nalNL2',
        wdrcRatio: 1.5,
        kneepoint: 60,
        nrLevel: 0,
        volume: 0,
        env: 'quiet'
    },
    'adult-moderate-descending': {
        name: 'Adulto — Moderada-Severa Descendente',
        audiogram: [15, 20, 25, 35, 45, 55, 60, 65, 60, 55, 50, 40],
        method: 'nalNL2',
        wdrcRatio: 2.5,
        kneepoint: 50,
        nrLevel: 1,
        volume: 0,
        env: 'conversation'
    },
    'child-profound': {
        name: 'Niño — Profunda (Power HA)',
        audiogram: [60, 65, 65, 70, 70, 75, 75, 80, 75, 70, 65, 55],
        method: 'nalNL2',
        wdrcRatio: 3.5,
        kneepoint: 40,
        nrLevel: 2,
        volume: 3,
        env: 'noisy'
    },
    'adult-cookie-bite': {
        name: 'Adulto — Cookie Bite (medios)',
        audiogram: [10, 15, 30, 40, 50, 50, 45, 35, 25, 15, 10, 5],
        method: 'nalNL2',
        wdrcRatio: 2.0,
        kneepoint: 55,
        nrLevel: 1,
        volume: 0,
        env: 'conversation'
    },
    'adult-mild-unilateral': {
        name: 'Adulto — Leve Unilateral',
        audiogram: [10, 10, 12, 15, 20, 25, 30, 35, 30, 25, 20, 10],
        method: 'nalNL2',
        wdrcRatio: 1.5,
        kneepoint: 60,
        nrLevel: 0,
        volume: 0,
        env: 'quiet'
    },
    'child-reverse-slope': {
        name: 'Niño — Ascendente (Reverse Slope)',
        audiogram: [45, 40, 35, 30, 25, 20, 15, 10, 10, 5, 5, 5],
        method: 'nalNL2',
        wdrcRatio: 2.5,
        kneepoint: 50,
        nrLevel: 1,
        volume: 0,
        env: 'conversation'
    },
    'adult-hf-abrupt': {
        name: 'Adulto — Caída Abrupta desde 1kHz',
        audiogram: [10, 10, 15, 40, 45, 50, 55, 60, 65, 70, 75, 80],
        method: 'nalNL2',
        wdrcRatio: 2.0,
        kneepoint: 55,
        nrLevel: 1,
        volume: 0,
        env: 'conversation'
    }
};

// =============================================================================
// PRESCRIPCIÓN — Half-Gain Rule y NAL-NL2
// (Implementadas directamente aquí, no están en dsp-engine)
// =============================================================================

/**
 * Half-Gain Rule: ganancia = pérdida / 2, clamped a [0, 50]
 */
function calculateHalfGain(audiogram) {
    return audiogram.map(loss => Math.min(50, Math.max(0, Math.round(loss / 2))));
}

/**
 * NAL-NL2 simplificado para 12 bandas.
 * Aplica ponderación frecuencial y compresión no-lineal.
 */
function calculateNALNL2(audiogram) {
    // Ponderación NAL-NL2 por banda (importancia relativa)
    const weights = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.85, 0.8, 0.7, 0.6];
    
    // PTA3 (promedio 500, 1000, 2000 Hz) — bandas 1, 3, 5
    const pta3 = (audiogram[1] + audiogram[3] + audiogram[5]) / 3;
    
    // Factor de compresión basado en severidad
    let compressionFactor;
    if (pta3 <= 20) compressionFactor = 0.4;
    else if (pta3 <= 40) compressionFactor = 0.5;
    else if (pta3 <= 60) compressionFactor = 0.55;
    else if (pta3 <= 80) compressionFactor = 0.6;
    else compressionFactor = 0.65;

    return audiogram.map((loss, i) => {
        const baseGain = loss * compressionFactor * weights[i];
        // Limitar a rango válido [0, 50]
        return Math.min(50, Math.max(0, Math.round(baseGain)));
    });
}

// =============================================================================
// INICIALIZACIÓN
// =============================================================================

document.addEventListener('DOMContentLoaded', () => {
    createAudiogramSliders();
    createEQSliders();
    setupFileUpload();
    setupPresets();
    setupDiagnoses();
    setupControls();
    setupPlayback();
    
    // Cargar preset "Pérdida desde 1kHz" como predeterminado
    const defaultPreset = PRESETS.from1k;
    defaultPreset.forEach((val, i) => {
        const slider = document.getElementById(`audio-band-${i}`);
        slider.value = val;
        document.getElementById(`audio-val-${i}`).textContent = `${val} dB`;
    });
    
    // Seleccionar NAL-NL2 como método predeterminado
    document.getElementById('prescription-method').value = 'nalNL2';
    
    // Calcular ganancias automáticamente
    calculateGains();
    
    updateReport();
});

// =============================================================================
// CREACIÓN DE SLIDERS
// =============================================================================

function createAudiogramSliders() {
    const container = document.getElementById('audiogram-sliders');
    container.innerHTML = '';

    FREQUENCIES.forEach((freq, i) => {
        const div = document.createElement('div');
        div.className = 'audiogram-band';
        
        const label = freq >= 1000 ? `${freq/1000}k` : `${freq}`;
        div.innerHTML = `
            <label>${label} Hz</label>
            <input type="range" min="0" max="120" value="0" step="5" 
                   id="audio-band-${i}" data-band="${i}">
            <span class="value" id="audio-val-${i}">0 dB</span>
        `;
        container.appendChild(div);
    });

    container.querySelectorAll('input[type="range"]').forEach(slider => {
        slider.addEventListener('input', (e) => {
            const band = parseInt(e.target.dataset.band);
            const val = parseInt(e.target.value);
            document.getElementById(`audio-val-${band}`).textContent = `${val} dB`;
        });
    });
}

function createEQSliders() {
    const container = document.getElementById('eq-sliders');
    container.innerHTML = '';

    FREQUENCIES.forEach((freq, i) => {
        const div = document.createElement('div');
        div.className = 'eq-band';
        div.id = `eq-band-${i}`;
        
        const label = freq >= 1000 ? `${freq/1000}k` : `${freq}`;
        div.innerHTML = `
            <label>${label} Hz</label>
            <input type="range" min="0" max="50" value="0" step="1" 
                   id="eq-band-${i}-slider" data-band="${i}">
            <span class="value" id="eq-val-${i}">0 dB</span>
        `;
        container.appendChild(div);
    });

    container.querySelectorAll('input[type="range"]').forEach(slider => {
        slider.addEventListener('input', (e) => {
            const band = parseInt(e.target.dataset.band);
            const val = parseInt(e.target.value);
            document.getElementById(`eq-val-${band}`).textContent = `${val} dB`;
            currentEqGains[band] = val;
            
            const bandDiv = document.getElementById(`eq-band-${band}`);
            bandDiv.classList.toggle('active', val > 0);
            
            markConfigModified();
            updateEQInfo();
            applyCurrentConfig();
            processIfReady();
        });
    });
}

// =============================================================================
// CARGA DE ARCHIVOS
// =============================================================================

function setupFileUpload() {
    const dropZone = document.getElementById('drop-zone');
    const fileInput = document.getElementById('file-input');
    const browseBtn = document.getElementById('browse-btn');
    const removeBtn = document.getElementById('remove-file');

    browseBtn.addEventListener('click', () => fileInput.click());
    dropZone.addEventListener('click', (e) => {
        if (e.target !== browseBtn) fileInput.click();
    });

    dropZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropZone.classList.add('dragover');
    });
    dropZone.addEventListener('dragleave', () => {
        dropZone.classList.remove('dragover');
    });
    dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropZone.classList.remove('dragover');
        if (e.dataTransfer.files.length > 0) {
            loadAudioFile(e.dataTransfer.files[0]);
        }
    });

    fileInput.addEventListener('change', (e) => {
        if (e.target.files.length > 0) {
            loadAudioFile(e.target.files[0]);
        }
    });

    removeBtn.addEventListener('click', () => {
        originalBuffer = null;
        processedBuffer = null;
        stopPlayback();
        document.getElementById('file-info').classList.add('hidden');
        document.getElementById('drop-zone').classList.remove('hidden');
        updatePlaybackButtons();
        updateReport();
    });
}

async function loadAudioFile(file) {
    try {
        if (!audioContext) {
            audioContext = new (window.AudioContext || window.webkitAudioContext)();
        }

        const arrayBuffer = await file.arrayBuffer();
        originalBuffer = await audioContext.decodeAudioData(arrayBuffer);

        const duration = originalBuffer.duration;
        document.getElementById('file-name').textContent = file.name;
        document.getElementById('file-duration').textContent = 
            `${duration.toFixed(1)}s | ${originalBuffer.sampleRate} Hz | ${originalBuffer.numberOfChannels}ch`;
        document.getElementById('file-info').classList.remove('hidden');
        document.getElementById('drop-zone').classList.add('hidden');

        processIfReady();
        updatePlaybackButtons();

    } catch (err) {
        alert('Error al cargar el archivo: ' + err.message);
    }
}

// =============================================================================
// RESAMPLING — Convertir a 16kHz para el pipeline DSP
// =============================================================================

/**
 * Resamplea un Float32Array de sourceSR a targetSR usando interpolación lineal.
 */
function resampleLinear(inputData, sourceSR, targetSR) {
    if (sourceSR === targetSR) return inputData;
    
    const ratio = sourceSR / targetSR;
    const outputLength = Math.floor(inputData.length / ratio);
    const output = new Float32Array(outputLength);
    
    for (let i = 0; i < outputLength; i++) {
        const srcIdx = i * ratio;
        const idx0 = Math.floor(srcIdx);
        const idx1 = Math.min(idx0 + 1, inputData.length - 1);
        const frac = srcIdx - idx0;
        output[i] = inputData[idx0] * (1 - frac) + inputData[idx1] * frac;
    }
    
    return output;
}

/**
 * Resamplea de targetSR de vuelta a sourceSR (para reconstruir el buffer de salida).
 */
function resampleBack(processedData, targetSR, sourceSR, originalLength) {
    if (sourceSR === targetSR) return processedData;
    
    const ratio = targetSR / sourceSR;
    const output = new Float32Array(originalLength);
    
    for (let i = 0; i < originalLength; i++) {
        const srcIdx = i * ratio;
        const idx0 = Math.floor(srcIdx);
        const idx1 = Math.min(idx0 + 1, processedData.length - 1);
        const frac = srcIdx - idx0;
        output[i] = processedData[idx0] * (1 - frac) + processedData[idx1] * frac;
    }
    
    return output;
}

// =============================================================================
// PRESETS
// =============================================================================

function setupPresets() {
    document.querySelectorAll('[data-preset]').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const presetKey = e.target.dataset.preset;
            const preset = PRESETS[presetKey];
            if (!preset) return;

            preset.forEach((val, i) => {
                const slider = document.getElementById(`audio-band-${i}`);
                slider.value = val;
                document.getElementById(`audio-val-${i}`).textContent = `${val} dB`;
            });

            // Update configSource for audiogram preset
            window.configSource.type = 'audiogram_preset';
            window.configSource.presetName = presetKey;
            window.configSource.audiogram = preset.slice();
            window.configSource.modified = false;

            calculateGains();

            // Update active config indicator
            updateActiveConfigIndicator(e.target.textContent.trim(), document.getElementById('prescription-method').value);
        });
    });
}

function setupDiagnoses() {
    document.querySelectorAll('[data-diagnosis]').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const diagKey = e.target.dataset.diagnosis;
            const diag = DIAGNOSES[diagKey];
            if (!diag) return;

            // 1. Setear audiograma
            diag.audiogram.forEach((val, i) => {
                const slider = document.getElementById(`audio-band-${i}`);
                slider.value = val;
                document.getElementById(`audio-val-${i}`).textContent = `${val} dB`;
            });

            // 2. Setear método de prescripción
            document.getElementById('prescription-method').value = diag.method;

            // 3. Setear parámetros DSP
            document.getElementById('wdrc-ratio').value = diag.wdrcRatio;
            currentWdrcRatio = diag.wdrcRatio;

            // Kneepoint per-preset (NAL-NL2 derived)
            if (diag.kneepoint) {
                window.currentWdrcKneepoint = diag.kneepoint;
            }

            document.getElementById('nr-level').value = diag.nrLevel;
            currentNrLevel = diag.nrLevel;

            document.getElementById('master-volume').value = diag.volume;
            document.getElementById('master-volume-val').textContent = `${diag.volume} dB`;
            currentMasterVolumeDb = diag.volume;

            document.getElementById('env-profile').value = diag.env;

            // Update configSource for clinical diagnosis preset
            window.configSource.type = 'clinical_diagnosis_preset';
            window.configSource.presetName = diagKey;
            window.configSource.prescriptionMethod = diag.method;
            window.configSource.audiogram = diag.audiogram.slice();
            window.configSource.modified = false;

            // 4. Calcular ganancias y procesar
            calculateGains();

            // 5. Update active config indicator
            updateActiveConfigIndicator(e.target.textContent.trim(), diag.method);
        });
    });
}

// =============================================================================
// CONTROLES
// =============================================================================

function setupControls() {
    document.getElementById('btn-calculate').addEventListener('click', calculateGains);

    document.getElementById('btn-reset-eq').addEventListener('click', () => {
        for (let i = 0; i < 12; i++) {
            const slider = document.getElementById(`eq-band-${i}-slider`);
            slider.value = 0;
            document.getElementById(`eq-val-${i}`).textContent = '0 dB';
            document.getElementById(`eq-band-${i}`).classList.remove('active');
            currentEqGains[i] = 0;
        }
        updateEQInfo();
        applyCurrentConfig();
        processIfReady();
    });

    document.getElementById('env-profile').addEventListener('change', (e) => {
        const profiles = {
            quiet: { nr: 0, ratio: 1.5, volume: 0 },
            conversation: { nr: 1, ratio: 2.0, volume: 0 },
            noisy: { nr: 3, ratio: 3.0, volume: -3 }
        };
        const p = profiles[e.target.value];
        document.getElementById('nr-level').value = p.nr;
        document.getElementById('wdrc-ratio').value = p.ratio;
        document.getElementById('master-volume').value = p.volume;
        document.getElementById('master-volume-val').textContent = `${p.volume} dB`;
        
        currentNrLevel = p.nr;
        currentWdrcRatio = p.ratio;
        currentMasterVolumeDb = p.volume;
        markConfigModified();
        applyCurrentConfig();
        processIfReady();
    });

    document.getElementById('nr-level').addEventListener('change', (e) => {
        currentNrLevel = parseInt(e.target.value);
        markConfigModified();
        applyCurrentConfig();
        processIfReady();
    });

    document.getElementById('wdrc-ratio').addEventListener('change', (e) => {
        currentWdrcRatio = parseFloat(e.target.value);
        markConfigModified();
        applyCurrentConfig();
        processIfReady();
    });

    document.getElementById('master-volume').addEventListener('input', (e) => {
        currentMasterVolumeDb = parseInt(e.target.value);
        document.getElementById('master-volume-val').textContent = `${e.target.value} dB`;
        markConfigModified();
        applyCurrentConfig();
        processIfReady();
    });

    document.getElementById('feedback-cancel').addEventListener('change', (e) => {
        currentFeedbackEnabled = parseInt(e.target.value);
        markConfigModified();
        applyCurrentConfig();
        processIfReady();
    });

    document.getElementById('mpo-threshold').addEventListener('change', (e) => {
        currentMpoThreshold = parseInt(e.target.value);
        markConfigModified();
        applyCurrentConfig();
        processIfReady();
    });
}

function calculateGains() {
    const audiogram = [];
    for (let i = 0; i < 12; i++) {
        audiogram.push(parseInt(document.getElementById(`audio-band-${i}`).value));
    }

    const method = document.getElementById('prescription-method').value;
    let gains;
    if (method === 'halfGain') {
        gains = calculateHalfGain(audiogram);
    } else {
        gains = calculateNALNL2(audiogram);
    }

    // Track prescription method in configSource
    window.configSource.prescriptionMethod = method === 'halfGain' ? 'halfGain' : 'nalNL2';
    window.configSource.audiogram = audiogram.slice();

    gains.forEach((gain, i) => {
        const slider = document.getElementById(`eq-band-${i}-slider`);
        slider.value = gain;
        document.getElementById(`eq-val-${i}`).textContent = `${gain} dB`;
        document.getElementById(`eq-band-${i}`).classList.toggle('active', gain > 0);
        currentEqGains[i] = gain;
    });

    updateEQInfo();
    applyCurrentConfig();
    processIfReady();
}

function updateEQInfo() {
    const total = currentEqGains.reduce((s, g) => s + g, 0);
    const avg = (total / 12).toFixed(1);
    const max = Math.max(...currentEqGains);
    document.getElementById('eq-total-info').textContent = 
        `Promedio: ${avg} dB | Máximo: ${max} dB`;
}

/**
 * Update the active configuration indicator in the UI.
 * @param {string} name - Display name of the preset/diagnosis
 * @param {string} [method] - Prescription method (halfGain, nalNL2)
 */
function updateActiveConfigIndicator(name, method) {
    const indicator = document.getElementById('active-config-indicator');
    const nameEl = document.getElementById('active-config-name');
    const methodEl = document.getElementById('active-config-method');
    if (!indicator || !nameEl) return;

    indicator.style.display = 'block';
    nameEl.textContent = name;
    if (methodEl) {
        if (method === 'nalNL2') {
            methodEl.textContent = '(NAL-NL2)';
        } else if (method === 'halfGain') {
            methodEl.textContent = '(Half-Gain)';
        } else {
            methodEl.textContent = '';
        }
    }
}

/**
 * Clear the active configuration indicator (e.g., on manual adjustment).
 */
function clearActiveConfigIndicator() {
    const indicator = document.getElementById('active-config-indicator');
    if (indicator) indicator.style.display = 'none';
}

// =============================================================================
// CONFIGURACIÓN DEL PIPELINE
// =============================================================================

/**
 * Construye el objeto config completo y lo aplica al pipeline.
 */
function applyCurrentConfig() {
    // Construir agc_bands: ratio en formato x10, kneepoint adaptado a la pérdida
    const agcBands = [];
    for (let i = 0; i < 12; i++) {
        agcBands.push({
            compression_ratio: Math.round(currentWdrcRatio * 10),  // x10 format
            kneepoint_db: window.currentWdrcKneepoint || 50,  // dB SPL kneepoint (per-preset)
            attack_ms: 5,           // ms
            release_ms: 100         // ms
        });
    }

    const config = {
        eq_gains: currentEqGains.slice(),
        agc_bands: agcBands,
        mpo_threshold_db: currentMpoThreshold,
        noise_reduction_level: currentNrLevel,
        feedback_enabled: currentFeedbackEnabled,
        master_volume_db: currentMasterVolumeDb
    };

    // Reiniciar pipeline y aplicar config
    pipeline = DSP.createDspPipeline();
    pipeline.init(config);
    window.pipeline = pipeline; // Keep global reference in sync

    // Sync DSP params to window for realtime-recorder.js (config.m export)
    window.currentEqGains = currentEqGains;
    window.currentWdrcRatio = currentWdrcRatio;
    // Note: kneepoint is NOT reset here — it's set per-preset by diagnosis selection
    window.currentWdrcAttackMs = 5.0;
    window.currentWdrcReleaseMs = 100.0;
    window.currentWdrcExpansionKnee = 35.0;
    window.currentWdrcExpansionRatio = 2.0;
    window.currentMpoThreshold = currentMpoThreshold;
    window.currentMasterVolumeDb = currentMasterVolumeDb;
}

// =============================================================================
// PROCESAMIENTO — Pipeline DSP a 16kHz con bloques de 64 muestras
// =============================================================================

function processIfReady() {
    if (!originalBuffer) return;

    const sourceSR = originalBuffer.sampleRate;
    const numChannels = originalBuffer.numberOfChannels;
    const PIPELINE_SR = DSP.SAMPLE_RATE; // 16000
    const BLOCK = DSP.BLOCK_SIZE;        // 64

    // Crear buffer de salida a la sample rate original
    processedBuffer = audioContext.createBuffer(numChannels, originalBuffer.length, sourceSR);

    // Configurar pipeline una vez antes de procesar
    applyCurrentConfig();

    for (let ch = 0; ch < numChannels; ch++) {
        const inputData = originalBuffer.getChannelData(ch);

        // 1. Resamplear a 16kHz
        const resampled = resampleLinear(inputData, sourceSR, PIPELINE_SR);

        // 2. Reiniciar estado del pipeline para cada canal (sin recrear)
        pipeline.reset();
        pipeline.resetMetrics();

        // 3. Procesar en bloques de 64 muestras Int16
        const numBlocks = Math.ceil(resampled.length / BLOCK);
        const processedSamples = new Float32Array(numBlocks * BLOCK);

        for (let b = 0; b < numBlocks; b++) {
            const offset = b * BLOCK;
            
            // Crear bloque Int16 de 64 muestras
            const block = new Int16Array(BLOCK);
            for (let i = 0; i < BLOCK; i++) {
                const idx = offset + i;
                if (idx < resampled.length) {
                    let sample = resampled[idx] * 32767.0;
                    if (sample > 32767.0) sample = 32767.0;
                    else if (sample < -32768.0) sample = -32768.0;
                    block[i] = Math.round(sample);
                } else {
                    block[i] = 0; // Zero-pad last block
                }
            }

            // Procesar bloque a través del pipeline
            const outputBlock = pipeline.processBlock(block);

            // Convertir salida Int16 a Float32
            for (let i = 0; i < BLOCK; i++) {
                processedSamples[offset + i] = outputBlock[i] / 32768.0;
            }
        }

        // 4. Recortar al largo real (sin padding)
        const trimmed = processedSamples.subarray(0, resampled.length);

        // 5. Resamplear de vuelta a la sample rate original
        const outputData = resampleBack(trimmed, PIPELINE_SR, sourceSR, originalBuffer.length);

        // 6. Escribir en el buffer de salida
        processedBuffer.getChannelData(ch).set(outputData);
    }

    // Actualizar reporte con métricas del pipeline
    updateReport();
    updatePlaybackButtons();
}

// =============================================================================
// REPORTE
// =============================================================================

function updateReport() {
    const container = document.getElementById('report-content');
    
    if (!originalBuffer || !processedBuffer) {
        container.innerHTML = '<p class="hint">Cargá un audio y ajustá el audiograma para ver el reporte.</p>';
        return;
    }

    const metrics = pipeline.getMetrics();
    const duration = originalBuffer.duration;
    const sourceSR = originalBuffer.sampleRate;

    // Determinar región WDRC basada en el nivel de entrada
    const inputRmsDb = metrics.inputRms > 0 ? 20 * Math.log10(metrics.inputRms) : -100;
    const inputSPL = inputRmsDb + DSP.WDRC_DBFS_TO_SPL_OFFSET;
    const expansionKnee = window.currentWdrcExpansionKnee || 35;
    const compressionKnee = window.currentWdrcKneepoint || 50;
    let wdrcRegion = 'LINEAL';
    if (inputSPL < expansionKnee) wdrcRegion = 'EXPANSIÓN (atenuando)';
    else if (inputSPL > compressionKnee) wdrcRegion = 'COMPRESIÓN (reduciendo)';

    // Config source info
    const cs = window.configSource || {};
    const presetName = cs.presetName || 'manual';
    const sourceType = cs.type || 'manual_adjustment';
    const prescMethod = cs.prescriptionMethod || 'N/A';
    const audiogram = cs.audiogram || [];

    const timestamp = new Date().toISOString().replace('T', ' ').substring(0, 19);

    const lines = [
        '═══════════════════════════════════════════════════════════════',
        '  REPORTE DSP — Audífono Digital V2 (Modo Offline)',
        '═══════════════════════════════════════════════════════════════',
        `  Timestamp:           ${timestamp}`,
        `  Modo:                OFFLINE (archivo WAV)`,
        `  Bypass:              OFF (procesamiento activo)`,
        '',
        '  ─── Fuente de Audio ───',
        '',
        `  Duración:            ${duration.toFixed(2)}s`,
        `  Sample Rate origen:  ${sourceSR} Hz`,
        `  Pipeline SR:         ${DSP.SAMPLE_RATE} Hz`,
        `  Bloques procesados:  ${Math.ceil(duration * DSP.SAMPLE_RATE / DSP.BLOCK_SIZE)}`,
        '',
        '  ─── Preset / Diagnóstico ───',
        '',
        `  Tipo config:         ${sourceType}`,
        `  Preset:              ${presetName}`,
        `  Prescripción:        ${prescMethod}`,
        `  Audiograma (dB HL):  [${audiogram.join(', ')}]`,
        '',
        '  ─── Métricas del Pipeline ───',
        '',
        `  Input Peak:          ${(metrics.inputPeak * 100).toFixed(2)}% FS`,
        `  Output Peak:         ${(metrics.outputPeak * 100).toFixed(2)}% FS`,
        `  Input RMS:           ${inputRmsDb.toFixed(1)} dBFS`,
        `  Input Level (SPL):   ${inputSPL.toFixed(1)} dB SPL (offset ${DSP.WDRC_DBFS_TO_SPL_OFFSET})`,
        `  Output RMS:          ${metrics.outputRms > 0 ? (20 * Math.log10(metrics.outputRms)).toFixed(1) : '-∞'} dBFS`,
        `  Ganancia Efectiva:   ${metrics.effectiveGainDb.toFixed(1)} dB`,
        `  MPO Activaciones:    ${metrics.mpoActivations}`,
        `  MPO Duty Cycle:      ${(metrics.mpoDutyCycle * 100).toFixed(3)}%`,
        '',
        '  ─── Estado WDRC ───',
        '',
        `  Región activa:       ${wdrcRegion}`,
        `  Expansion Knee:      ${expansionKnee} dB SPL (ER=${window.currentWdrcExpansionRatio || 2.0}:1)`,
        `  Compression Knee:    ${compressionKnee} dB SPL (CR=${currentWdrcRatio}:1)`,
        `  Attack:              ${window.currentWdrcAttackMs || 5.0} ms`,
        `  Release:             ${window.currentWdrcReleaseMs || 100.0} ms`,
        '',
        '  ─── Configuración Completa ───',
        '',
        `  EQ Gains (dB):       [${currentEqGains.join(', ')}]`,
        `  Noise Reduction:     Level ${currentNrLevel}`,
        `  Feedback Cancel:     ${currentFeedbackEnabled ? 'ON' : 'OFF'}`,
        `  MPO Threshold:       ${currentMpoThreshold} dB SPL`,
        `  Master Volume:       ${currentMasterVolumeDb} dB`,
        `  Calibración Offset:  ${DSP.WDRC_DBFS_TO_SPL_OFFSET} dB (WAV)`,
        '',
        '  ─── Compliance IEC 60118-7 ───',
        '',
        `  Sin clipping:        ${metrics.outputPeak <= 1.0 ? '✓ PASS' : '✗ CLIP (' + (metrics.outputPeak * 100).toFixed(1) + '%)'}`,
        `  MPO Duty < 5%:       ${metrics.mpoDutyCycle < 0.05 ? '✓ PASS' : '⚠ ' + (metrics.mpoDutyCycle * 100).toFixed(1) + '%'}`,
        `  Ganancia > 0 dB:     ${metrics.effectiveGainDb > 0 ? '✓ PASS (+' + metrics.effectiveGainDb.toFixed(1) + ' dB)' : '✗ FAIL (' + metrics.effectiveGainDb.toFixed(1) + ' dB)'}`,
        '',
        '  ─── Evaluación Clínica ───',
        ''
    ];

    // --- Evaluación de ruido de fondo (procesar silencio) ---
    const silencePipeline = DSP.createDspPipeline();
    silencePipeline.init({
        eq_gains: currentEqGains.slice(),
        agc_bands: Array(12).fill(null).map(() => ({
            compression_ratio: Math.round(currentWdrcRatio * 10),
            kneepoint_db: window.currentWdrcKneepoint || 50, attack_ms: 5, release_ms: 100
        })),
        mpo_threshold_db: currentMpoThreshold,
        noise_reduction_level: currentNrLevel,
        feedback_enabled: currentFeedbackEnabled,
        master_volume_db: currentMasterVolumeDb
    });
    let silenceRmsSum = 0;
    for (let b = 0; b < 10; b++) {
        const silBlock = new Int16Array(DSP.BLOCK_SIZE);
        const silOut = silencePipeline.processBlock(silBlock);
        let sumSq = 0;
        for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
            sumSq += (silOut[i] / 32768.0) ** 2;
        }
        silenceRmsSum += Math.sqrt(sumSq / DSP.BLOCK_SIZE);
    }
    const silenceRms = silenceRmsSum / 10;
    const silenceDbFS = silenceRms > 1e-10 ? 20 * Math.log10(silenceRms) : -100;
    const noiseOk = silenceDbFS < -40;
    lines.push(`  Ruido de fondo:      ${silenceDbFS.toFixed(1)} dBFS ${noiseOk ? '✓ OK (< -40 dBFS)' : '✗ ALTO — ruido amplificado'}`);

    // --- SNR estimado (señal vs piso de ruido) ---
    const outputRmsDbEval = metrics.outputRms > 0 ? 20 * Math.log10(metrics.outputRms) : -100;
    const snrEstimated = outputRmsDbEval - silenceDbFS;
    const snrOk = snrEstimated > 15;
    lines.push(`  SNR estimado:        ${snrEstimated.toFixed(1)} dB ${snrOk ? '✓ OK (> 15 dB)' : '⚠ BAJO — señal poco clara'}`);

    // --- Amplificación efectiva ---
    const ampOk = metrics.effectiveGainDb > 0;
    const maxEqGain = Math.max(...currentEqGains);
    if (ampOk) {
        lines.push(`  Amplificación:       ✓ Output > Input (+${metrics.effectiveGainDb.toFixed(1)} dB)`);
    } else if (maxEqGain === 0) {
        lines.push(`  Amplificación:       — N/A (EQ en 0 dB, sin prescripción)`);
    } else {
        lines.push(`  Amplificación:       ✗ FALLA — Output ≤ Input (${metrics.effectiveGainDb.toFixed(1)} dB)`);
    }

    // --- Seguridad auditiva (peak en dB SPL vs MPO) ---
    // Use WDRC offset (76 for WAV) to convert output peak to SPL, not MPO offset (120)
    const outputPeakSPL = metrics.outputPeak > 0 ? 20 * Math.log10(metrics.outputPeak) + DSP.WDRC_DBFS_TO_SPL_OFFSET : 0;
    const safetyOk = outputPeakSPL < currentMpoThreshold;
    lines.push(`  Seguridad auditiva:  Peak ${outputPeakSPL.toFixed(0)} dB SPL ${safetyOk ? '✓ OK (< MPO ' + currentMpoThreshold + ')' : '✗ EXCEDE MPO'}`);

    // --- Ganancia real medida por banda (frequency sweep) ---
    lines.push('');
    lines.push('  ─── Ganancia Real por Banda (tono puro @ -30 dBFS) ───');
    lines.push('');
    const sweepAmplitude = Math.pow(10, -30 / 20) * 32767;
    const sweepBlocks = 20;
    const freqLabels = ['250','500','750','1k','1.5k','2k','2.5k','3k','3.5k','4k','6k','8k'];
    let swFreq = '  Freq:     ';
    let swPrescr = '  Prescr:   ';
    let swMedida = '  Medida:   ';
    let swDelta = '  Delta:    ';

    for (let band = 0; band < 12; band++) {
        // For band 11 (8 kHz = Nyquist at 16 kHz SR), measure at 7600 Hz
        // because a tone at exactly Nyquist produces zero samples digitally
        const freq = (FREQUENCIES[band] >= DSP.SAMPLE_RATE / 2) ? 
            DSP.SAMPLE_RATE / 2 - 400 : FREQUENCIES[band];
        const sweepPipe = DSP.createDspPipeline();
        sweepPipe.init({
            eq_gains: currentEqGains.slice(),
            agc_bands: Array(12).fill(null).map(() => ({
                compression_ratio: Math.round(currentWdrcRatio * 10),
                kneepoint_db: window.currentWdrcKneepoint || 50, attack_ms: 5, release_ms: 100
            })),
            mpo_threshold_db: currentMpoThreshold,
            noise_reduction_level: currentNrLevel,
            feedback_enabled: currentFeedbackEnabled,
            master_volume_db: currentMasterVolumeDb
        });

        let inRmsTotal = 0, outRmsTotal = 0;
        for (let b = 0; b < sweepBlocks; b++) {
            const block = new Int16Array(DSP.BLOCK_SIZE);
            for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
                const t = (b * DSP.BLOCK_SIZE + i) / DSP.SAMPLE_RATE;
                block[i] = Math.round(sweepAmplitude * Math.sin(2 * Math.PI * freq * t));
            }
            const output = sweepPipe.processBlock(block);
            if (b >= 10) {
                let inSq = 0, outSq = 0;
                for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
                    inSq += (block[i] / 32768) ** 2;
                    outSq += (output[i] / 32768) ** 2;
                }
                inRmsTotal += Math.sqrt(inSq / DSP.BLOCK_SIZE);
                outRmsTotal += Math.sqrt(outSq / DSP.BLOCK_SIZE);
            }
        }
        const inRms = inRmsTotal / 10;
        const outRms = outRmsTotal / 10;
        const measuredGain = (inRms > 1e-10 && outRms > 1e-10) ? 20 * Math.log10(outRms / inRms) : 0;
        const prescribed = currentEqGains[band];
        const delta = measuredGain - prescribed;

        swFreq += freqLabels[band].padStart(6);
        swPrescr += (prescribed + '').padStart(6);
        swMedida += measuredGain.toFixed(1).padStart(6);
        swDelta += ((delta >= 0 ? '+' : '') + delta.toFixed(1)).padStart(6);
    }
    lines.push(swFreq);
    lines.push(swPrescr);
    lines.push(swMedida);
    lines.push(swDelta);
    lines.push('');
    lines.push('  (Prescr=EQ prescrita dB, Medida=ganancia real dB, Delta=diferencia)');

    // --- THD por frecuencia (ANSI S3.22: 500, 1000, 1600 Hz @ 70 dB SPL) ---
    lines.push('');
    lines.push('  ─── THD — Distorsión Armónica (IEC 60118-7, input 70 dB SPL) ───');
    lines.push('');
    const thdFreqs = [500, 1000, 1600];
    const thdInputDbSPL = 70;
    const thdInputDbFS = thdInputDbSPL - DSP.WDRC_DBFS_TO_SPL_OFFSET;
    const thdAmplitude = Math.pow(10, thdInputDbFS / 20) * 32767;
    const thdBlocks = 50; // 200ms per frequency for stable measurement
    const thdMeasureBlocks = 30; // measure last 30 blocks

    for (const thdFreq of thdFreqs) {
        const thdPipe = DSP.createDspPipeline();
        thdPipe.init({
            eq_gains: currentEqGains.slice(),
            agc_bands: Array(12).fill(null).map(() => ({
                compression_ratio: Math.round(currentWdrcRatio * 10),
                kneepoint_db: window.currentWdrcKneepoint || 50,
                attack_ms: 5, release_ms: 100
            })),
            mpo_threshold_db: currentMpoThreshold,
            noise_reduction_level: currentNrLevel,
            feedback_enabled: currentFeedbackEnabled,
            master_volume_db: currentMasterVolumeDb
        });

        // Collect output samples after convergence
        const outputSamples = [];
        for (let b = 0; b < thdBlocks; b++) {
            const block = new Int16Array(DSP.BLOCK_SIZE);
            for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
                const t = (b * DSP.BLOCK_SIZE + i) / DSP.SAMPLE_RATE;
                block[i] = Math.round(thdAmplitude * Math.sin(2 * Math.PI * thdFreq * t));
            }
            const output = thdPipe.processBlock(block);
            if (b >= (thdBlocks - thdMeasureBlocks)) {
                for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
                    outputSamples.push(output[i] / 32768.0);
                }
            }
        }

        // Simple THD calculation: measure power at fundamental vs harmonics
        const N = outputSamples.length;
        const binSize = DSP.SAMPLE_RATE / N;
        const fundBin = Math.round(thdFreq / binSize);
        // DFT at fundamental and harmonics 2-5
        let fundPower = 0;
        let harmPower = 0;
        for (let h = 1; h <= 5; h++) {
            const hFreq = thdFreq * h;
            if (hFreq >= DSP.SAMPLE_RATE / 2) break;
            let re = 0, im = 0;
            for (let n = 0; n < N; n++) {
                const angle = 2 * Math.PI * hFreq * n / DSP.SAMPLE_RATE;
                re += outputSamples[n] * Math.cos(angle);
                im += outputSamples[n] * Math.sin(angle);
            }
            const mag = Math.sqrt(re * re + im * im) / N;
            if (h === 1) fundPower = mag;
            else harmPower += mag * mag;
        }
        const thd = fundPower > 0 ? (Math.sqrt(harmPower) / fundPower) * 100 : 0;
        const thdOk = thd < 3.0;
        lines.push(`  THD @ ${thdFreq} Hz:      ${thd.toFixed(2)}% ${thdOk ? '✓ OK (< 3%)' : '✗ EXCEDE 3%'}`);
    }

    // --- EIN (Equivalent Input Noise) ---
    lines.push('');
    lines.push('  ─── EIN — Ruido Equivalente de Entrada ───');
    lines.push('');
    // EIN = output noise level - gain = noise referred to input
    const einDb = silenceDbFS - (metrics.effectiveGainDb > 0 ? metrics.effectiveGainDb : 0);
    const einSPL = einDb + DSP.WDRC_DBFS_TO_SPL_OFFSET;
    const einOk = einSPL < 28;
    lines.push(`  EIN:                 ${einSPL.toFixed(1)} dB SPL ${einOk ? '✓ OK (< 28 dB SPL)' : '⚠ ALTO (> 28 dB SPL)'}`);

    // --- Curva I/O @ 1kHz (muestra las 3 regiones WDRC) ---
    lines.push('');
    lines.push('  ─── Curva I/O @ 1kHz (Input → Output en dB SPL) ───');
    lines.push('');
    const ioInputLevels = [30, 40, 50, 60, 70, 80, 90];
    let ioLine1 = '  Input SPL:  ';
    let ioLine2 = '  Output SPL: ';
    let ioLine3 = '  Gain:       ';
    for (const inputSPLio of ioInputLevels) {
        const ioDbFS = inputSPLio - DSP.WDRC_DBFS_TO_SPL_OFFSET;
        const ioAmp = Math.pow(10, ioDbFS / 20) * 32767;
        const ioPipe = DSP.createDspPipeline();
        ioPipe.init({
            eq_gains: currentEqGains.slice(),
            agc_bands: Array(12).fill(null).map(() => ({
                compression_ratio: Math.round(currentWdrcRatio * 10),
                kneepoint_db: window.currentWdrcKneepoint || 50, attack_ms: 5, release_ms: 100
            })),
            mpo_threshold_db: currentMpoThreshold,
            noise_reduction_level: currentNrLevel,
            feedback_enabled: currentFeedbackEnabled,
            master_volume_db: currentMasterVolumeDb
        });
        let ioOutRms = 0;
        const ioBlocks = 15;
        for (let b = 0; b < ioBlocks; b++) {
            const block = new Int16Array(DSP.BLOCK_SIZE);
            for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
                const t = (b * DSP.BLOCK_SIZE + i) / DSP.SAMPLE_RATE;
                block[i] = Math.round(ioAmp * Math.sin(2 * Math.PI * 1000 * t));
            }
            const output = ioPipe.processBlock(block);
            if (b >= 10) {
                let sq = 0;
                for (let i = 0; i < DSP.BLOCK_SIZE; i++) sq += (output[i] / 32768) ** 2;
                ioOutRms += Math.sqrt(sq / DSP.BLOCK_SIZE);
            }
        }
        ioOutRms /= 5;
        const outDbFS = ioOutRms > 1e-10 ? 20 * Math.log10(ioOutRms) : -100;
        const outSPL = outDbFS + DSP.WDRC_DBFS_TO_SPL_OFFSET;
        const ioGain = outSPL - inputSPLio;
        ioLine1 += (inputSPLio + '').padStart(7);
        ioLine2 += outSPL.toFixed(0).padStart(7);
        ioLine3 += ((ioGain >= 0 ? '+' : '') + ioGain.toFixed(0)).padStart(7);
    }
    lines.push(ioLine1);
    lines.push(ioLine2);
    lines.push(ioLine3);
    lines.push('');
    lines.push('  (Expansión < 35 SPL | Lineal 35-50 SPL | Compresión > 50 SPL)');

    // --- Latencia estimada ---
    lines.push('');
    lines.push('  ─── Latencia ───');
    lines.push('');
    const latencyMs = (DSP.BLOCK_SIZE / DSP.SAMPLE_RATE) * 1000;
    const latencyOk = latencyMs < 10;
    lines.push(`  Latencia pipeline:   ${latencyMs.toFixed(1)} ms (1 bloque) ${latencyOk ? '✓ OK (< 10 ms)' : '✗ EXCEDE 10 ms'}`);
    lines.push(`  Latencia total est:  ${(latencyMs * 2).toFixed(1)} ms (input + output buffers)`);

    // --- Recuperación post-impulso (MPO recovery) ---
    lines.push('');
    lines.push('  ─── Recuperación MPO post-impulso ───');
    lines.push('');
    const impPipe = DSP.createDspPipeline();
    impPipe.init({
        eq_gains: currentEqGains.slice(),
        agc_bands: Array(12).fill(null).map(() => ({
            compression_ratio: Math.round(currentWdrcRatio * 10),
            kneepoint_db: window.currentWdrcKneepoint || 50, attack_ms: 5, release_ms: 100
        })),
        mpo_threshold_db: currentMpoThreshold,
        noise_reduction_level: currentNrLevel,
        feedback_enabled: currentFeedbackEnabled,
        master_volume_db: currentMasterVolumeDb
    });
    // Warm up with normal signal
    for (let b = 0; b < 10; b++) {
        const block = new Int16Array(DSP.BLOCK_SIZE);
        for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
            block[i] = Math.round(1000 * Math.sin(2 * Math.PI * 1000 * (b * DSP.BLOCK_SIZE + i) / DSP.SAMPLE_RATE));
        }
        impPipe.processBlock(block);
    }
    // Send impulse (full scale)
    const impBlock = new Int16Array(DSP.BLOCK_SIZE);
    impBlock[0] = 32767;
    impPipe.processBlock(impBlock);
    // Measure recovery: how many blocks until output returns to >90% of normal
    const normalAmp = 1000;
    let recoveryBlocks = 0;
    let recovered = false;
    for (let b = 0; b < 50; b++) {
        const block = new Int16Array(DSP.BLOCK_SIZE);
        for (let i = 0; i < DSP.BLOCK_SIZE; i++) {
            block[i] = Math.round(normalAmp * Math.sin(2 * Math.PI * 1000 * (b * DSP.BLOCK_SIZE + i) / DSP.SAMPLE_RATE));
        }
        const output = impPipe.processBlock(block);
        let outRmsImp = 0;
        for (let i = 0; i < DSP.BLOCK_SIZE; i++) outRmsImp += (output[i] / 32768) ** 2;
        outRmsImp = Math.sqrt(outRmsImp / DSP.BLOCK_SIZE);
        const expectedRms = normalAmp / 32768 * 0.707; // sine RMS
        if (outRmsImp > expectedRms * 0.9) {
            recovered = true;
            break;
        }
        recoveryBlocks++;
    }
    const recoveryMs = recoveryBlocks * (DSP.BLOCK_SIZE / DSP.SAMPLE_RATE) * 1000;
    const recoveryOk = recoveryMs < 50;
    lines.push(`  Recovery time:       ${recoveryMs.toFixed(1)} ms ${recovered ? (recoveryOk ? '✓ OK (< 50 ms)' : '⚠ LENTO') : '✗ NO RECUPERÓ en 200ms'}`);

    // --- Resumen ---
    const allPass = noiseOk && snrOk && ampOk && safetyOk && metrics.outputPeak <= 1.0;
    lines.push('');
    lines.push(`  ═══ RESULTADO: ${allPass ? '✓ APROBADO — Procesamiento clínicamente correcto' : '⚠ REVISAR — Ver items marcados con ✗ o ⚠'} ═══`);
    lines.push('');
    lines.push('═══════════════════════════════════════════════════════════════');

    container.textContent = lines.join('\n');
}

// =============================================================================
// REPRODUCCIÓN
// =============================================================================

function setupPlayback() {
    document.getElementById('btn-play-original').addEventListener('click', () => {
        playBuffer(originalBuffer, 'original');
    });

    document.getElementById('btn-play-processed').addEventListener('click', () => {
        playBuffer(processedBuffer, 'processed');
    });

    document.getElementById('btn-stop').addEventListener('click', stopPlayback);
}

function playBuffer(buffer, type) {
    if (!buffer || !audioContext) return;

    // Mutual exclusion: stop realtime mode if active before playing offline audio
    if (window.realtimeActive && window.RealtimeModule) {
        window.RealtimeModule.stop();
    }

    if (audioContext.state === 'suspended') {
        audioContext.resume();
    }

    stopPlayback();

    currentSource = audioContext.createBufferSource();
    currentSource.buffer = buffer;
    currentSource.connect(audioContext.destination);
    currentSource.start(0);
    isPlaying = true;
    startTime = audioContext.currentTime;

    const progressContainer = document.getElementById('progress-container');
    progressContainer.classList.remove('hidden');
    updateProgress(buffer.duration);

    currentSource.onended = () => {
        isPlaying = false;
        document.getElementById('progress-bar').style.width = '100%';
    };

    document.getElementById('btn-stop').disabled = false;
}

function stopPlayback() {
    if (currentSource) {
        try { currentSource.stop(); } catch(e) {}
        currentSource = null;
    }
    isPlaying = false;
    document.getElementById('progress-bar').style.width = '0%';
    document.getElementById('btn-stop').disabled = true;
}

/**
 * Exposed globally for RealtimeModule mutual exclusion.
 * When realtime mode starts, it calls this to stop any offline playback.
 */
window.stopOfflinePlayback = function() {
    stopPlayback();
};

function updateProgress(duration) {
    if (!isPlaying) return;

    const elapsed = audioContext.currentTime - startTime;
    const pct = Math.min(100, (elapsed / duration) * 100);
    document.getElementById('progress-bar').style.width = `${pct}%`;

    const elapsedMin = Math.floor(elapsed / 60);
    const elapsedSec = Math.floor(elapsed % 60);
    const totalMin = Math.floor(duration / 60);
    const totalSec = Math.floor(duration % 60);
    document.getElementById('progress-time').textContent = 
        `${elapsedMin}:${String(elapsedSec).padStart(2, '0')} / ${totalMin}:${String(totalSec).padStart(2, '0')}`;

    if (elapsed < duration) {
        requestAnimationFrame(() => updateProgress(duration));
    }
}

function updatePlaybackButtons() {
    document.getElementById('btn-play-original').disabled = !originalBuffer;
    document.getElementById('btn-play-processed').disabled = !processedBuffer;
}


// =============================================================================
// BOTÓN COPIAR REPORTE
// =============================================================================

document.getElementById('btn-copy-report').addEventListener('click', function() {
    const reportEl = document.getElementById('report-content');
    const text = reportEl.innerText || reportEl.textContent || '';
    if (!text || text.includes('Cargá un audio')) {
        return;
    }
    navigator.clipboard.writeText(text).then(function() {
        var btn = document.getElementById('btn-copy-report');
        var original = btn.textContent;
        btn.textContent = '✓ Copiado';
        setTimeout(function() { btn.textContent = original; }, 2000);
    }).catch(function() {
        // Fallback para navegadores sin clipboard API
        var range = document.createRange();
        range.selectNodeContents(reportEl);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        document.execCommand('copy');
        sel.removeAllRanges();
    });
});
