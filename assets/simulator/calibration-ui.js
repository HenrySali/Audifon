/**
 * Calibration UI — ANSI S3.22 Self-Calibration Simulator Interface
 *
 * Integrates the CalibrationSimulator into the web simulator UI.
 * Allows users to simulate hardware degradation and see the auto-calibration
 * system detect it, compute the Degradation Index, and apply compensation.
 */

'use strict';

// ============================================================================
// Inline CalibrationSimulator (browser-compatible, no require())
// ============================================================================

const CALIB_NUM_BANDS = 12;
const CALIB_BAND_FREQS = [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000];

const CALIB_BASELINE = {
  ospl90_db: [1100, 1120, 1140, 1150, 1160, 1170, 1160, 1150, 1130, 1100, 1060, 1010],
  full_on_gain_db: [350, 380, 400, 420, 440, 450, 440, 420, 400, 370, 340, 300],
  hfa_ospl90_x10: 1150,
  hfa_fog_x10: 430,
  ein_db_x10: 250,
  thd_percent_x100: [80, 60, 90],
  battery_drain_x10: 12
};

const CALIB_PROFILES = {
  receiver_aging: {
    ospl90: [5, 8, 12, 18, 25, 35, 45, 55, 65, 75, 85, 95],
    fog: [3, 5, 8, 12, 18, 25, 32, 40, 48, 55, 62, 70],
    ein: 15, thd: [30, 25, 40], battery: 5
  },
  mic_drift: {
    ospl90: [20, 18, 15, 12, 10, 8, 10, 12, 15, 20, 25, 30],
    fog: [15, 12, 10, 8, 6, 5, 6, 8, 10, 15, 18, 22],
    ein: 35, thd: [15, 20, 25], battery: 3
  },
  battery_degradation: {
    ospl90: [2, 2, 3, 3, 4, 5, 5, 6, 6, 7, 7, 8],
    fog: [1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6],
    ein: 8, thd: [10, 12, 15], battery: 35
  }
};

function computeCalibration(profileName, intensity) {
  if (!profileName || profileName === 'none') {
    return { di: 0, severity: 0, compensation: new Array(12).fill(0), capped: 0, metrics: null };
  }

  const profile = CALIB_PROFILES[profileName];
  const k = intensity;

  // Simulate current measurement with degradation
  const current_ospl = CALIB_BASELINE.ospl90_db.map((v, i) => v - Math.round(profile.ospl90[i] * k));
  const current_fog = CALIB_BASELINE.full_on_gain_db.map((v, i) => v - Math.round(profile.fog[i] * k));
  const current_ein = CALIB_BASELINE.ein_db_x10 + Math.round(profile.ein * k);
  const current_thd = CALIB_BASELINE.thd_percent_x100.map((v, i) => v + Math.round(profile.thd[i] * k));
  const current_batt = Math.round(CALIB_BASELINE.battery_drain_x10 * (1 + profile.battery * k / 100));

  // Compute DI components
  let ospl_sum = 0, fog_sum = 0;
  for (let i = 0; i < 12; i++) {
    ospl_sum += Math.abs(CALIB_BASELINE.ospl90_db[i] - current_ospl[i]);
    fog_sum += Math.abs(CALIB_BASELINE.full_on_gain_db[i] - current_fog[i]);
  }
  const norm_ospl = Math.min(1.0, (ospl_sum / 12) / 30);
  const norm_fog = Math.min(1.0, (fog_sum / 12) / 20);
  const norm_ein = Math.min(1.0, Math.abs(current_ein - CALIB_BASELINE.ein_db_x10) / 30);
  let thd_sum = 0;
  for (let i = 0; i < 3; i++) thd_sum += Math.abs(current_thd[i] - CALIB_BASELINE.thd_percent_x100[i]);
  const norm_thd = Math.min(1.0, (thd_sum / 3) / 100);
  const batt_pct = CALIB_BASELINE.battery_drain_x10 > 0
    ? Math.abs(current_batt - CALIB_BASELINE.battery_drain_x10) / CALIB_BASELINE.battery_drain_x10 * 100 : 0;
  const norm_batt = Math.min(1.0, batt_pct / 20);

  let di = 0.30 * norm_ospl + 0.30 * norm_fog + 0.15 * norm_ein + 0.15 * norm_thd + 0.10 * norm_batt;
  di = Math.max(0, Math.min(1, di));

  const severity = di < 0.3 ? 0 : di <= 0.7 ? 1 : 2;

  // Compensation curve
  const compensation = [];
  let capped = 0;
  for (let i = 0; i < 12; i++) {
    let diff = CALIB_BASELINE.full_on_gain_db[i] - current_fog[i];
    if (diff <= 0) {
      compensation.push(0);
    } else if (diff > 100) {
      compensation.push(100);
      if (i < 8) capped |= (1 << i);
    } else {
      compensation.push(diff);
    }
  }

  // Metrics
  const hfa_ospl = Math.round((current_ospl[3] + current_ospl[5] + current_ospl[7]) / 3);
  const hfa_fog = Math.round((current_fog[3] + current_fog[5] + current_fog[7]) / 3);

  return {
    di, severity, compensation, capped,
    metrics: {
      hfa_ospl90: hfa_ospl / 10,
      hfa_fog: hfa_fog / 10,
      ein: current_ein / 10,
      thd_1k: current_thd[0] / 100,
      battery: current_batt / 10
    }
  };
}

// ============================================================================
// UI Logic
// ============================================================================

(function() {
  const profileSelect = document.getElementById('calib-profile');
  const intensitySlider = document.getElementById('calib-intensity');
  const intensityVal = document.getElementById('calib-intensity-val');
  const btnRun = document.getElementById('btn-run-selfcheck');
  const btnReset = document.getElementById('btn-reset-degradation');
  const resultDiv = document.getElementById('calib-result');

  if (!profileSelect || !btnRun) return; // Guard if elements don't exist

  // Intensity slider display
  intensitySlider.addEventListener('input', () => {
    const val = (parseInt(intensitySlider.value) / 100).toFixed(1);
    intensityVal.textContent = val + '×';
  });

  // Run self-check
  btnRun.addEventListener('click', () => {
    const profile = profileSelect.value;
    const intensity = parseInt(intensitySlider.value) / 100;

    const result = computeCalibration(profile, intensity);
    displayResult(result);
  });

  // Reset
  btnReset.addEventListener('click', () => {
    profileSelect.value = 'none';
    intensitySlider.value = 100;
    intensityVal.textContent = '1.0×';
    resultDiv.classList.add('hidden');
  });

  function displayResult(result) {
    resultDiv.classList.remove('hidden');

    // DI gauge
    const diFill = document.getElementById('di-fill');
    const diValue = document.getElementById('di-value');
    const diLabel = document.getElementById('di-label');

    const diPct = (result.di * 100).toFixed(1);
    diFill.style.width = diPct + '%';

    if (result.severity === 0) {
      diFill.style.background = '#4CAF50';
      diLabel.textContent = 'Sin degradación significativa';
      diLabel.style.color = '#4CAF50';
    } else if (result.severity === 1) {
      diFill.style.background = '#FF9800';
      diLabel.textContent = 'Degradación moderada — compensación automática aplicada';
      diLabel.style.color = '#FF9800';
    } else {
      diFill.style.background = '#F44336';
      diLabel.textContent = 'Degradación severa — servicio profesional recomendado';
      diLabel.style.color = '#F44336';
    }
    diValue.textContent = diPct + '%';

    // Metrics
    if (result.metrics) {
      document.getElementById('metric-ospl90').textContent = result.metrics.hfa_ospl90.toFixed(1) + ' dB';
      document.getElementById('metric-fog').textContent = result.metrics.hfa_fog.toFixed(1) + ' dB';
      document.getElementById('metric-ein').textContent = result.metrics.ein.toFixed(1) + ' dB SPL';
      document.getElementById('metric-thd').textContent = result.metrics.thd_1k.toFixed(2) + '%';
      document.getElementById('metric-battery').textContent = result.metrics.battery.toFixed(1) + ' mA';
    } else {
      ['metric-ospl90', 'metric-fog', 'metric-ein', 'metric-thd', 'metric-battery']
        .forEach(id => document.getElementById(id).textContent = '—');
    }

    // Compensation bars
    const compBars = document.getElementById('comp-bars');
    compBars.innerHTML = '';

    for (let i = 0; i < 12; i++) {
      const compDb = result.compensation[i] / 10; // x10 → dB
      const maxHeight = 100; // px
      const height = Math.min(maxHeight, (compDb / 10) * maxHeight);
      const isCapped = (result.capped & (1 << i)) !== 0;

      const bar = document.createElement('div');
      bar.className = 'comp-bar-container';
      bar.innerHTML = `
        <div class="comp-bar" style="height:${height}px; background:${isCapped ? '#FF9800' : '#4CAF50'}"></div>
        <span class="comp-bar-value">${compDb.toFixed(1)}</span>
        <span class="comp-bar-freq">${formatFreq(CALIB_BAND_FREQS[i])}</span>
      `;
      compBars.appendChild(bar);
    }
  }

  function formatFreq(hz) {
    return hz >= 1000 ? (hz / 1000) + 'k' : hz + '';
  }
})();
