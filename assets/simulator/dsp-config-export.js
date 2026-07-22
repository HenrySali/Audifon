/**
 * DSP Configuration Export Module
 * 
 * Captures the complete DSP pipeline state from the web simulator and serializes
 * it into formats compatible with external verification tools (Matlab, Simulink,
 * LabVIEW, JSON).
 * 
 * Exposes its API on window.DspConfigExport.
 * No external dependencies — vanilla JavaScript only.
 */
(function () {
  'use strict';

  // ─────────────────────────────────────────────────────────────────────────────
  // CRC32 Implementation (ISO 3720, polynomial 0xEDB88320, reflected)
  // ─────────────────────────────────────────────────────────────────────────────

  /**
   * Pre-computed 256-entry CRC32 lookup table using the standard ISO 3720
   * polynomial 0xEDB88320 (reflected representation of 0x04C11DB7).
   * Generated once at module load time for O(1) per-byte lookups.
   */
  var CRC32_TABLE = (function () {
    var table = new Uint32Array(256);
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var j = 0; j < 8; j++) {
        if (crc & 1) {
          crc = (crc >>> 1) ^ 0xEDB88320;
        } else {
          crc = crc >>> 1;
        }
      }
      table[i] = crc;
    }
    return table;
  })();

  /**
   * Compute CRC32 checksum of a configuration snapshot.
   * 
   * Serializes the snapshot to canonical JSON (no whitespace), encodes it as
   * UTF-8 bytes using TextEncoder, and computes the CRC32 using the pre-computed
   * lookup table.
   * 
   * @param {object} snapshot - The ConfigSnapshot object to checksum.
   * @returns {number} - Unsigned 32-bit integer CRC32 value.
   */
  function computeCRC32(snapshot) {
    var json = JSON.stringify(snapshot);
    var bytes = new TextEncoder().encode(json);
    var crc = 0xFFFFFFFF;

    for (var i = 0; i < bytes.length; i++) {
      crc = (crc >>> 8) ^ CRC32_TABLE[(crc ^ bytes[i]) & 0xFF];
    }

    // Final XOR and unsigned shift to get a positive 32-bit value
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Constants
  // ─────────────────────────────────────────────────────────────────────────────

  var NUM_BANDS = 12;
  var BIQUADS_PER_BAND = 2;
  var SAMPLE_RATE = 16000;
  var BLOCK_SIZE = 64;
  var SIMULATOR_VERSION = '1.0.0';
  var CENTER_FREQUENCIES = [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000];

  // ─────────────────────────────────────────────────────────────────────────────
  // Utility: Reverse time coefficient back to milliseconds
  // ─────────────────────────────────────────────────────────────────────────────

  /**
   * Reverse the calculateTimeCoefficient formula to recover the original time in ms.
   * Formula: coeff = 1 - exp(-1 / (timeMs * sampleRate / 1000))
   * Inverse: timeMs = -1000 / (sampleRate * ln(1 - coeff))
   *
   * @param {number} coeff - The time coefficient stored in the WDRC state.
   * @returns {number} - Time in milliseconds (rounded to 1 decimal).
   */
  function coeffToTimeMs(coeff) {
    if (coeff <= 0 || coeff >= 1) return 0;
    var samples = -1.0 / Math.log(1.0 - coeff);
    return Math.round((samples * 1000.0 / SAMPLE_RATE) * 10) / 10;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Snapshot Capture
  // ─────────────────────────────────────────────────────────────────────────────

  /**
   * Capture the current DSP pipeline state into a ConfigSnapshot.
   * 
   * Reads EQ biquad coefficients, WDRC parameters, MPO threshold,
   * compensation gains, audiogram data, and configuration source metadata
   * from the live pipeline and app state.
   *
   * @returns {object} ConfigSnapshot
   */
  function captureSnapshot() {
    var pipe = window.pipeline;
    if (!pipe || !pipe.equalizer || !pipe.wdrc || !pipe.mpoLimiter) {
      throw new Error('Pipeline DSP no inicializado. Cargá un audio primero.');
    }

    // --- Read EQ biquad coefficients (12 bands × 2 biquads × 5 coefficients) ---
    var eqBands = [];
    for (var band = 0; band < NUM_BANDS; band++) {
      var biquads = [];
      for (var bq = 0; bq < BIQUADS_PER_BAND; bq++) {
        var filter = pipe.equalizer.filters[band][bq];
        biquads.push({
          b0: filter.b0,
          b1: filter.b1,
          b2: filter.b2,
          a1: filter.a1,
          a2: filter.a2
        });
      }
      eqBands.push({
        band_index: band,
        center_frequency_hz: CENTER_FREQUENCIES[band],
        gain_db: pipe.equalizer.gainsDb[band],
        biquads: biquads
      });
    }

    // --- Read WDRC parameters (ratio, kneepoint, attack_ms, release_ms per band) ---
    var wdrcParams = [];
    for (var i = 0; i < NUM_BANDS; i++) {
      var state = pipe.wdrc.states[i];
      wdrcParams.push({
        band_index: i,
        ratio: state.ratio,
        kneepoint_db: state.thresholdDb,
        attack_ms: coeffToTimeMs(state.attackCoeff),
        release_ms: coeffToTimeMs(state.releaseCoeff)
      });
    }

    // --- Read MPO threshold ---
    var mpoThreshold = pipe.mpoLimiter.state.thresholdDb;

    // --- Read compensation gains from calibration state ---
    var compensationActive = false;
    var compensationGains = new Array(NUM_BANDS).fill(0.0);
    var degradationIndex = 0.0;
    var calibrationProfile = null;

    // Check if calibration UI has been run (look for result in DOM or global state)
    var calibProfileEl = document.getElementById('calib-profile');
    var calibIntensityEl = document.getElementById('calib-intensity');
    if (calibProfileEl && calibIntensityEl) {
      var profileName = calibProfileEl.value;
      var intensity = parseInt(calibIntensityEl.value) / 100;
      if (profileName && profileName !== 'none' && intensity > 0) {
        var calibResult = computeCalibration(profileName, intensity);
        if (calibResult && calibResult.di > 0) {
          compensationActive = true;
          degradationIndex = calibResult.di;
          calibrationProfile = profileName;
          for (var c = 0; c < NUM_BANDS; c++) {
            // compensation values from computeCalibration are in x10 format (tenths of dB)
            compensationGains[c] = calibResult.compensation[c] / 10.0;
          }
        }
      }
    }

    // --- Read audiogram thresholds and prescription gains from app state ---
    var audiogramThresholds = new Array(NUM_BANDS).fill(0);
    var prescriptionGains = new Array(NUM_BANDS).fill(0);

    // Read audiogram from DOM sliders (source of truth)
    for (var a = 0; a < NUM_BANDS; a++) {
      var slider = document.getElementById('audio-band-' + a);
      if (slider) {
        audiogramThresholds[a] = parseInt(slider.value) || 0;
      }
    }

    // Prescription gains are the current EQ gains (calculated from audiogram)
    for (var p = 0; p < NUM_BANDS; p++) {
      var eqSlider = document.getElementById('eq-band-' + p + '-slider');
      if (eqSlider) {
        prescriptionGains[p] = parseInt(eqSlider.value) || 0;
      }
    }

    // --- Read configuration source ---
    var configSrc = window.configSource || {
      type: 'manual_adjustment',
      presetName: null,
      prescriptionMethod: null,
      audiogram: null,
      modified: false
    };

    // --- Assemble metadata ---
    var metadata = {
      sample_rate: SAMPLE_RATE,
      block_size: BLOCK_SIZE,
      num_bands: NUM_BANDS,
      center_frequencies: CENTER_FREQUENCIES.slice(),
      export_timestamp: new Date().toISOString(),
      configuration_source: configSrc.type,
      preset_name: configSrc.presetName || null,
      prescription_method: configSrc.prescriptionMethod || null,
      simulator_version: SIMULATOR_VERSION
    };

    // --- Assemble ConfigSnapshot ---
    return {
      metadata: metadata,
      eq_bands: eqBands,
      wdrc: wdrcParams,
      mpo: {
        threshold_db_spl: mpoThreshold
      },
      compensation: {
        active: compensationActive,
        gains_db: compensationGains,
        degradation_index: degradationIndex,
        calibration_profile: calibrationProfile
      },
      audiogram: {
        thresholds_db_hl: audiogramThresholds,
        frequencies_hz: CENTER_FREQUENCIES.slice(),
        prescription_gains_db: prescriptionGains
      }
    };
  }

  /**
   * Validate a snapshot against firmware-defined ranges.
   * @param {object} snapshot - The ConfigSnapshot to validate.
   * @returns {{ valid: boolean, errors: string[] }}
   */
  function validateSnapshot(snapshot) {
    var errors = [];

    // Validate EQ biquad coefficients are finite
    if (snapshot.eq_bands) {
      for (var b = 0; b < snapshot.eq_bands.length; b++) {
        var band = snapshot.eq_bands[b];
        if (band.biquads) {
          for (var bq = 0; bq < band.biquads.length; bq++) {
            var coeffs = band.biquads[bq];
            var names = ['b0', 'b1', 'b2', 'a1', 'a2'];
            for (var c = 0; c < names.length; c++) {
              var val = coeffs[names[c]];
              if (typeof val !== 'number' || !isFinite(val)) {
                errors.push('EQ band ' + b + ' biquad ' + bq + ' coefficient ' + names[c] + ' is not finite: ' + val);
              }
            }
          }
        }
      }
    }

    // Validate WDRC parameters per band
    if (snapshot.wdrc) {
      for (var w = 0; w < snapshot.wdrc.length; w++) {
        var wdrc = snapshot.wdrc[w];
        if (typeof wdrc.ratio !== 'number' || wdrc.ratio < 1.0 || wdrc.ratio > 4.0) {
          errors.push('WDRC band ' + w + ' ratio out of range [1.0, 4.0]: ' + wdrc.ratio);
        }
        if (typeof wdrc.kneepoint_db !== 'number' || wdrc.kneepoint_db < 40 || wdrc.kneepoint_db > 80) {
          errors.push('WDRC band ' + w + ' kneepoint_db out of range [40, 80]: ' + wdrc.kneepoint_db);
        }
        if (typeof wdrc.attack_ms !== 'number' || wdrc.attack_ms < 1 || wdrc.attack_ms > 10) {
          errors.push('WDRC band ' + w + ' attack_ms out of range [1, 10]: ' + wdrc.attack_ms);
        }
        if (typeof wdrc.release_ms !== 'number' || wdrc.release_ms < 50 || wdrc.release_ms > 500) {
          errors.push('WDRC band ' + w + ' release_ms out of range [50, 500]: ' + wdrc.release_ms);
        }
      }
    }

    // Validate MPO threshold
    if (snapshot.mpo) {
      var mpo = snapshot.mpo.threshold_db_spl;
      if (typeof mpo !== 'number' || mpo < 90 || mpo > 110) {
        errors.push('MPO threshold_db_spl out of range [90, 110]: ' + mpo);
      }
    }

    return { valid: errors.length === 0, errors: errors };
  }

  /**
   * Trigger a browser file download with the given content and filename.
   * Creates a Blob, generates an object URL, and programmatically clicks
   * a hidden anchor element to initiate the download.
   *
   * @param {string} content - The file content to download.
   * @param {string} filename - The filename for the downloaded file.
   */
  function triggerDownload(content, filename) {
    if (typeof Blob === 'undefined' || typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') {
      throw new Error('Tu navegador no soporta la descarga de archivos.');
    }

    var mimeType = 'text/plain;charset=utf-8';
    if (filename.endsWith('.json')) {
      mimeType = 'application/json;charset=utf-8';
    }

    var blob = new Blob([content], { type: mimeType });
    var url = URL.createObjectURL(blob);

    var anchor = document.createElement('a');
    anchor.style.display = 'none';
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();

    // Clean up: remove anchor and revoke URL after a short delay
    setTimeout(function () {
      document.body.removeChild(anchor);
      URL.revokeObjectURL(url);
    }, 100);
  }

  /**
   * Generate a timestamped filename for the export.
   * Pattern: dsp_config_<format>_<YYYYMMDD_HHmmss>.<ext>
   *
   * @param {string} format - The export format ('matlab' | 'json' | 'simulink' | 'labview').
   * @returns {string} The generated filename.
   */
  function generateFilename(format) {
    var now = new Date();
    var year = now.getFullYear();
    var month = String(now.getMonth() + 1).padStart(2, '0');
    var day = String(now.getDate()).padStart(2, '0');
    var hours = String(now.getHours()).padStart(2, '0');
    var minutes = String(now.getMinutes()).padStart(2, '0');
    var seconds = String(now.getSeconds()).padStart(2, '0');

    var timestamp = year + month + day + '_' + hours + minutes + seconds;

    var ext;
    if (format === 'matlab' || format === 'simulink') {
      ext = 'm';
    } else {
      ext = 'json';
    }

    return 'dsp_config_' + format + '_' + timestamp + '.' + ext;
  }

  /**
   * Export the current configuration in the specified format.
   * Orchestrates: capture → validate → serialize → download.
   * @param {'matlab' | 'json' | 'simulink' | 'labview'} format
   * @returns {{ success: boolean, error?: string, filename?: string }}
   */
  function exportConfig(format) {
    try {
      // Validate format parameter
      var validFormats = ['matlab', 'json', 'simulink', 'labview'];
      if (validFormats.indexOf(format) === -1) {
        return { success: false, error: 'Formato no soportado: ' + format };
      }

      // Step 1: Capture snapshot
      var snapshot = captureSnapshot();

      // Step 2: Validate snapshot
      var validation = validateSnapshot(snapshot);
      if (!validation.valid) {
        return { success: false, error: validation.errors.join('; ') };
      }

      // Step 3: Compute CRC32
      var crcValue = computeCRC32(snapshot);
      var crcHex = '0x' + crcValue.toString(16).toUpperCase().padStart(8, '0');

      // Step 4: Route to the correct serializer
      var content;
      switch (format) {
        case 'json':
          content = serializeJSON(snapshot, crcHex);
          break;
        case 'matlab':
          content = serializeMatlab(snapshot, crcHex);
          break;
        case 'simulink':
          content = serializeSimulink(snapshot, crcHex);
          break;
        case 'labview':
          content = serializeLabVIEW(snapshot, crcHex);
          break;
      }

      // Step 5: Generate filename
      var filename = generateFilename(format);

      // Step 6: Trigger download
      triggerDownload(content, filename);

      // Step 7: Return success
      return { success: true, filename: filename };

    } catch (err) {
      return { success: false, error: err.message || String(err) };
    }
  }

  /**
   * Serialize a snapshot to JSON format.
   *
   * Produces a valid RFC 8259 JSON document with 2-space indentation.
   * The output includes top-level keys: metadata, eq_bands, wdrc, mpo,
   * compensation, audiogram. The CRC32 hex string is embedded in
   * metadata.crc32 for integrity verification on import.
   *
   * @param {object} snapshot - The ConfigSnapshot.
   * @param {string} crc - CRC32 hex string (e.g., "0xA1B2C3D4").
   * @returns {string} JSON string (UTF-8, RFC 8259 compliant).
   */
  function serializeJSON(snapshot, crc) {
    // Build the output object with the specified top-level key order
    var output = {
      metadata: Object.assign({}, snapshot.metadata, { crc32: crc }),
      eq_bands: snapshot.eq_bands,
      wdrc: snapshot.wdrc,
      mpo: snapshot.mpo,
      compensation: snapshot.compensation,
      audiogram: snapshot.audiogram
    };

    // JSON.stringify with 2-space indentation produces valid RFC 8259 JSON.
    // JavaScript strings are UTF-16 internally; JSON.stringify only emits
    // ASCII-safe characters (escaping anything outside Basic Latin), which
    // guarantees valid UTF-8 when saved to a file.
    return JSON.stringify(output, null, 2);
  }

  /**
   * Serialize a snapshot to Matlab script format (.m).
   * Generates a valid .m script that creates workspace variables when executed
   * in Matlab R2020a or later.
   *
   * @param {object} snapshot - The ConfigSnapshot.
   * @param {string} crc - CRC32 hex string (e.g., '0xA1B2C3D4').
   * @returns {string} Matlab script content.
   */
  function serializeMatlab(snapshot, crc) {
    var lines = [];
    var meta = snapshot.metadata;

    // --- Header comments ---
    lines.push('% DSP Configuration Export — Hearing Aid Simulator');
    var sourceLabel = meta.configuration_source || 'manual_adjustment';
    if (meta.preset_name) {
      lines.push('% Source: ' + sourceLabel + ' (' + meta.preset_name + ')');
    } else {
      lines.push('% Source: ' + sourceLabel);
    }
    lines.push('% Exported: ' + meta.export_timestamp);
    lines.push('% CRC32: ' + crc);
    if (meta.prescription_method) {
      lines.push('% Prescription Method: ' + meta.prescription_method);
    }
    lines.push('% Simulator Version: ' + meta.simulator_version);
    lines.push('');

    // --- Pipeline constants ---
    lines.push('% Pipeline constants');
    lines.push('sample_rate = ' + meta.sample_rate + ';');
    lines.push('block_size = ' + meta.block_size + ';');
    lines.push('num_bands = ' + meta.num_bands + ';');
    lines.push('center_frequencies = [' + meta.center_frequencies.join(', ') + '];');
    lines.push('');

    // --- EQ Biquad Coefficients: 12×2×5 matrix ---
    lines.push('% EQ Biquad Coefficients: bands(12) x biquads(2) x coeffs(5) [b0, b1, b2, a1, a2]');
    lines.push('eq_biquads = zeros(12, 2, 5);');
    for (var band = 0; band < snapshot.eq_bands.length; band++) {
      var eqBand = snapshot.eq_bands[band];
      for (var bq = 0; bq < eqBand.biquads.length; bq++) {
        var coeffs = eqBand.biquads[bq];
        var coeffArr = [
          formatMatlabNum(coeffs.b0),
          formatMatlabNum(coeffs.b1),
          formatMatlabNum(coeffs.b2),
          formatMatlabNum(coeffs.a1),
          formatMatlabNum(coeffs.a2)
        ];
        lines.push('eq_biquads(' + (band + 1) + ',' + (bq + 1) + ',:) = [' + coeffArr.join(', ') + '];');
      }
    }
    lines.push('');

    // --- EQ Gains (dB per band) ---
    lines.push('% EQ Gains (dB per band)');
    var gains = [];
    for (var g = 0; g < snapshot.eq_bands.length; g++) {
      gains.push(formatMatlabNum(snapshot.eq_bands[g].gain_db));
    }
    lines.push('eq_gains = [' + gains.join(', ') + '];');
    lines.push('');

    // --- WDRC Parameters (struct array) ---
    lines.push('% WDRC Parameters (struct array)');
    lines.push("wdrc = struct('ratio', {}, 'kneepoint', {}, 'attack_ms', {}, 'release_ms', {});");
    for (var w = 0; w < snapshot.wdrc.length; w++) {
      var wdrc = snapshot.wdrc[w];
      lines.push(
        'wdrc(' + (w + 1) + ') = struct(' +
        "'ratio', " + formatMatlabNum(wdrc.ratio) + ', ' +
        "'kneepoint', " + formatMatlabNum(wdrc.kneepoint_db) + ', ' +
        "'attack_ms', " + formatMatlabNum(wdrc.attack_ms) + ', ' +
        "'release_ms', " + formatMatlabNum(wdrc.release_ms) + ');'
      );
    }
    lines.push('');

    // --- MPO Threshold ---
    lines.push('% MPO Threshold');
    lines.push('mpo_threshold_db_spl = ' + formatMatlabNum(snapshot.mpo.threshold_db_spl) + ';');
    lines.push('');

    // --- Compensation curve ---
    lines.push('% Compensation curve (dB)');
    var compGains = [];
    for (var c = 0; c < snapshot.compensation.gains_db.length; c++) {
      compGains.push(formatMatlabNum(snapshot.compensation.gains_db[c]));
    }
    lines.push('compensation_gains = [' + compGains.join(', ') + '];');
    lines.push('compensation_active = ' + (snapshot.compensation.active ? 'true' : 'false') + ';');
    lines.push('');

    // --- Audiogram data ---
    lines.push('% Audiogram data');
    var thresholds = [];
    for (var t = 0; t < snapshot.audiogram.thresholds_db_hl.length; t++) {
      thresholds.push(formatMatlabNum(snapshot.audiogram.thresholds_db_hl[t]));
    }
    lines.push('audiogram_thresholds_db_hl = [' + thresholds.join(', ') + '];');

    var freqs = [];
    for (var f = 0; f < snapshot.audiogram.frequencies_hz.length; f++) {
      freqs.push(String(snapshot.audiogram.frequencies_hz[f]));
    }
    lines.push('audiogram_frequencies_hz = [' + freqs.join(', ') + '];');

    var prescGains = [];
    for (var pg = 0; pg < snapshot.audiogram.prescription_gains_db.length; pg++) {
      prescGains.push(formatMatlabNum(snapshot.audiogram.prescription_gains_db[pg]));
    }
    lines.push('prescription_gains_db = [' + prescGains.join(', ') + '];');
    lines.push('');

    return lines.join('\n');
  }

  /**
   * Format a number for Matlab output with sufficient precision.
   * Uses up to 15 significant digits for floating-point values.
   * Integers are output without decimal places.
   *
   * @param {number} val - The numeric value to format.
   * @returns {string} Formatted number string.
   */
  function formatMatlabNum(val) {
    if (typeof val !== 'number' || !isFinite(val)) {
      return 'NaN';
    }
    // If it's an integer, output without decimals
    if (Number.isInteger(val)) {
      return String(val);
    }
    // Use toPrecision with 15 digits to preserve full double precision,
    // then remove trailing zeros after the decimal point for readability
    var s = val.toPrecision(15);
    // Remove trailing zeros but keep at least one decimal digit
    if (s.indexOf('.') !== -1) {
      s = s.replace(/0+$/, '');
      if (s.charAt(s.length - 1) === '.') {
        s += '0';
      }
    }
    return s;
  }

  /**
   * Serialize a snapshot to Simulink-compatible format (.m).
   * Outputs SOS matrix in Nx6 format (24 rows: 12 bands × 2 biquads)
   * and WDRC as Simulink.Parameter-compatible struct.
   *
   * @param {object} snapshot - The ConfigSnapshot.
   * @param {string} crc - CRC32 hex string.
   * @returns {string} Simulink script content.
   */
  function serializeSimulink(snapshot, crc) {
    var lines = [];
    var meta = snapshot.metadata;

    // ── Header with loading instructions ──
    lines.push('%% DSP Configuration Export — Simulink Model Workspace');
    lines.push('% Source: ' + (meta.configuration_source || 'manual_adjustment') +
      (meta.preset_name ? ' (' + meta.preset_name + ')' : ''));
    lines.push('% Exported: ' + (meta.export_timestamp || new Date().toISOString()));
    lines.push('% CRC32: ' + crc);
    lines.push('% Simulator version: ' + (meta.simulator_version || SIMULATOR_VERSION));
    lines.push('%');
    lines.push('% ─── Loading Instructions ───');
    lines.push('% 1. Open your Simulink model.');
    lines.push('% 2. Open Model Explorer (View > Model Explorer) or the Model Workspace.');
    lines.push('% 3. In the Model Workspace, select "MATLAB Code" as the data source.');
    lines.push('% 4. Paste or run this script to populate the workspace variables.');
    lines.push('% 5. Use sos_matrix with the "Biquad Filter" block (set to SOS matrix input).');
    lines.push('% 6. Use wdrc_params with MATLAB Function blocks for dynamic compression.');
    lines.push('% 7. Use mpo_threshold with a Saturation block for output limiting.');
    lines.push('%');
    lines.push('% Pipeline: 12-band EQ (2 biquads/band) → WDRC → MPO Limiter');
    lines.push('% Sample rate: ' + meta.sample_rate + ' Hz, Block size: ' + meta.block_size);
    lines.push('');

    // ── Pipeline constants ──
    lines.push('%% Pipeline Constants');
    lines.push('sample_rate = ' + meta.sample_rate + ';');
    lines.push('block_size = ' + meta.block_size + ';');
    lines.push('num_bands = ' + meta.num_bands + ';');
    lines.push('center_frequencies = [' + meta.center_frequencies.join(', ') + '];');
    lines.push('');

    // ── SOS Matrix (24 rows × 6 columns) ──
    // Each row: [b0, b1, b2, 1, a1, a2] — a0 normalized to 1.0
    // Order: band0_bq0, band0_bq1, band1_bq0, band1_bq1, ..., band11_bq1
    lines.push('%% SOS Matrix for Simulink "Biquad Filter" block');
    lines.push('% Each row: [b0, b1, b2, 1, a1, a2] (a0 normalized to 1)');
    lines.push('% Rows: band1_bq1, band1_bq2, band2_bq1, band2_bq2, ..., band12_bq2');
    lines.push('% Total: ' + (NUM_BANDS * BIQUADS_PER_BAND) + ' rows (12 bands x 2 biquads)');
    lines.push('sos_matrix = [');

    for (var b = 0; b < snapshot.eq_bands.length; b++) {
      var band = snapshot.eq_bands[b];
      for (var bq = 0; bq < band.biquads.length; bq++) {
        var c = band.biquads[bq];
        // Column 4 is always 1.0 (a0 normalized)
        var row = '  ' +
          formatMatlabNum(c.b0) + ', ' +
          formatMatlabNum(c.b1) + ', ' +
          formatMatlabNum(c.b2) + ', ' +
          '1, ' +
          formatMatlabNum(c.a1) + ', ' +
          formatMatlabNum(c.a2);
        // Add semicolon separator between rows, last row gets none
        var isLast = (b === snapshot.eq_bands.length - 1 && bq === band.biquads.length - 1);
        lines.push(row + (isLast ? '' : ';'));
      }
    }
    lines.push('];');
    lines.push('');

    // ── EQ Gains ──
    lines.push('%% EQ Gains (dB per band)');
    var gains = [];
    for (var g = 0; g < snapshot.eq_bands.length; g++) {
      gains.push(formatMatlabNum(snapshot.eq_bands[g].gain_db));
    }
    lines.push('eq_gains = [' + gains.join(', ') + '];');
    lines.push('');

    // ── WDRC as Simulink.Parameter-compatible struct ──
    lines.push('%% WDRC Parameters (Simulink.Parameter-compatible struct)');
    lines.push('% Use with MATLAB Function blocks or Simulink.Parameter objects');
    lines.push('wdrc_params = struct( ...');
    lines.push("    'num_bands', " + NUM_BANDS + ', ...');
    lines.push("    'ratio', [" + snapshot.wdrc.map(function (w) { return formatMatlabNum(w.ratio); }).join(', ') + '], ...');
    lines.push("    'kneepoint_db', [" + snapshot.wdrc.map(function (w) { return formatMatlabNum(w.kneepoint_db); }).join(', ') + '], ...');
    lines.push("    'attack_ms', [" + snapshot.wdrc.map(function (w) { return formatMatlabNum(w.attack_ms); }).join(', ') + '], ...');
    lines.push("    'release_ms', [" + snapshot.wdrc.map(function (w) { return formatMatlabNum(w.release_ms); }).join(', ') + '] ...');
    lines.push(');');
    lines.push('');

    // ── MPO Threshold ──
    lines.push('%% MPO Threshold');
    lines.push('mpo_threshold = ' + formatMatlabNum(snapshot.mpo.threshold_db_spl) + ';');
    lines.push('');

    // ── Compensation ──
    lines.push('%% Compensation Curve');
    lines.push('compensation_active = ' + (snapshot.compensation.active ? 'true' : 'false') + ';');
    lines.push('compensation_gains = [' + snapshot.compensation.gains_db.map(function (g) { return formatMatlabNum(g); }).join(', ') + '];');
    lines.push('');

    // ── Audiogram ──
    lines.push('%% Audiogram Data');
    lines.push('audiogram_thresholds = [' + snapshot.audiogram.thresholds_db_hl.map(function (t) { return formatMatlabNum(t); }).join(', ') + '];');
    lines.push('audiogram_frequencies = [' + snapshot.audiogram.frequencies_hz.join(', ') + '];');
    lines.push('prescription_gains = [' + snapshot.audiogram.prescription_gains_db.map(function (g) { return formatMatlabNum(g); }).join(', ') + '];');
    lines.push('');

    // ── Simulink.Parameter wrappers (optional convenience) ──
    lines.push('%% Simulink.Parameter Wrappers (for Model Workspace)');
    lines.push("% Uncomment to create Simulink.Parameter objects:");
    lines.push("% sos_param = Simulink.Parameter(sos_matrix);");
    lines.push("% sos_param.StorageClass = 'Auto';");
    lines.push("% wdrc_param = Simulink.Parameter(wdrc_params);");
    lines.push("% wdrc_param.StorageClass = 'Auto';");
    lines.push("% mpo_param = Simulink.Parameter(mpo_threshold);");
    lines.push("% mpo_param.StorageClass = 'Auto';");

    return lines.join('\n');
  }

  /**
   * Serialize a snapshot to LabVIEW-compatible JSON format.
   * Structures output as LabVIEW cluster-compatible JSON with explicit type
   * annotations on every leaf value, dimension metadata on arrays, and
   * step-by-step import instructions.
   *
   * @param {object} snapshot - The ConfigSnapshot.
   * @param {string} crc - CRC32 hex string.
   * @returns {string} LabVIEW JSON string with 2-space indentation.
   */
  function serializeLabVIEW(snapshot, crc) {
    var meta = snapshot.metadata;

    // --- Build metadata cluster ---
    var metadataCluster = {
      type: 'Cluster',
      sample_rate: { type: 'I32', value: meta.sample_rate },
      block_size: { type: 'I32', value: meta.block_size },
      num_bands: { type: 'I32', value: meta.num_bands },
      center_frequencies: {
        type: 'Array',
        dimensions: [meta.center_frequencies.length],
        value: meta.center_frequencies.map(function (f) {
          return { type: 'I32', value: f };
        })
      },
      export_timestamp: { type: 'String', value: meta.export_timestamp },
      configuration_source: { type: 'String', value: meta.configuration_source },
      preset_name: { type: 'String', value: meta.preset_name || '' },
      prescription_method: { type: 'String', value: meta.prescription_method || '' },
      simulator_version: { type: 'String', value: meta.simulator_version },
      crc32: { type: 'String', value: crc }
    };

    // --- Build EQ bands array ---
    var eqBandsValue = snapshot.eq_bands.map(function (band) {
      var biquadsValue = band.biquads.map(function (bq) {
        return {
          type: 'Cluster',
          b0: { type: 'DBL', value: bq.b0 },
          b1: { type: 'DBL', value: bq.b1 },
          b2: { type: 'DBL', value: bq.b2 },
          a1: { type: 'DBL', value: bq.a1 },
          a2: { type: 'DBL', value: bq.a2 }
        };
      });

      return {
        type: 'Cluster',
        band_index: { type: 'I32', value: band.band_index },
        center_frequency_hz: { type: 'I32', value: band.center_frequency_hz },
        gain_db: { type: 'DBL', value: band.gain_db },
        biquads: {
          type: 'Array',
          dimensions: [biquadsValue.length],
          value: biquadsValue
        }
      };
    });

    var eqBands = {
      type: 'Array',
      dimensions: [eqBandsValue.length],
      value: eqBandsValue
    };

    // --- Build WDRC array ---
    var wdrcValue = snapshot.wdrc.map(function (w) {
      return {
        type: 'Cluster',
        band_index: { type: 'I32', value: w.band_index },
        ratio: { type: 'DBL', value: w.ratio },
        kneepoint_db: { type: 'DBL', value: w.kneepoint_db },
        attack_ms: { type: 'DBL', value: w.attack_ms },
        release_ms: { type: 'DBL', value: w.release_ms }
      };
    });

    var wdrc = {
      type: 'Array',
      dimensions: [wdrcValue.length],
      value: wdrcValue
    };

    // --- Build MPO cluster ---
    var mpo = {
      type: 'Cluster',
      threshold_db_spl: { type: 'DBL', value: snapshot.mpo.threshold_db_spl }
    };

    // --- Build compensation cluster ---
    var compensation = {
      type: 'Cluster',
      active: { type: 'Boolean', value: snapshot.compensation.active },
      gains_db: {
        type: 'Array',
        dimensions: [snapshot.compensation.gains_db.length],
        value: snapshot.compensation.gains_db.map(function (g) {
          return { type: 'DBL', value: g };
        })
      },
      degradation_index: { type: 'DBL', value: snapshot.compensation.degradation_index },
      calibration_profile: { type: 'String', value: snapshot.compensation.calibration_profile || '' }
    };

    // --- Build audiogram cluster ---
    var audiogram = {
      type: 'Cluster',
      thresholds_db_hl: {
        type: 'Array',
        dimensions: [snapshot.audiogram.thresholds_db_hl.length],
        value: snapshot.audiogram.thresholds_db_hl.map(function (t) {
          return { type: 'DBL', value: t };
        })
      },
      frequencies_hz: {
        type: 'Array',
        dimensions: [snapshot.audiogram.frequencies_hz.length],
        value: snapshot.audiogram.frequencies_hz.map(function (f) {
          return { type: 'I32', value: f };
        })
      },
      prescription_gains_db: {
        type: 'Array',
        dimensions: [snapshot.audiogram.prescription_gains_db.length],
        value: snapshot.audiogram.prescription_gains_db.map(function (g) {
          return { type: 'DBL', value: g };
        })
      }
    };

    // --- Import instructions ---
    var importInstructions =
      '1. Open LabVIEW 2020 or later.\n' +
      '2. Create a new VI or open your DSP verification VI.\n' +
      '3. On the block diagram, place "Unflatten From JSON" (Data Communication > JSON palette).\n' +
      '4. Wire a "Read from Text File" function to read this exported .json file.\n' +
      '5. Connect the file content string to the "JSON string" input of "Unflatten From JSON".\n' +
      '6. Create a LabVIEW cluster constant matching the structure of this file (metadata, eq_bands, wdrc, mpo, compensation, audiogram).\n' +
      '7. Wire the cluster constant to the "type" input to define the expected data types.\n' +
      '8. The output cluster will contain all DSP parameters ready for use in your verification VI.\n' +
      '9. Verify the CRC32 checksum in metadata.crc32 matches the expected value: ' + crc + '.\n' +
      '10. Use the eq_bands array to configure your biquad filter simulation blocks.\n' +
      '11. Use the wdrc array to configure compression parameters per band.';

    // --- Assemble top-level LabVIEW cluster ---
    var output = {
      type: 'Cluster',
      metadata: metadataCluster,
      eq_bands: eqBands,
      wdrc: wdrc,
      mpo: mpo,
      compensation: compensation,
      audiogram: audiogram,
      labview_import_instructions: { type: 'String', value: importInstructions }
    };

    return JSON.stringify(output, null, 2);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────────

  window.DspConfigExport = {
    computeCRC32: computeCRC32,
    captureSnapshot: captureSnapshot,
    validateSnapshot: validateSnapshot,
    exportConfig: exportConfig,
    triggerDownload: triggerDownload,
    serializeJSON: serializeJSON,
    serializeMatlab: serializeMatlab,
    serializeSimulink: serializeSimulink,
    serializeLabVIEW: serializeLabVIEW
  };

})();
