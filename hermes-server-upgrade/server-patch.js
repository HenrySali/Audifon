// =============================================================================
// Hermes Adaptive Learning Server — v2 (Collective Learning + Persistence)
//
// Upgraded server for the Audifon adaptive hearing-aid platform.
// Replaces /var/www/OirPro K/adaptive-learning/server.js on the VPS.
//
// Changes from v1:
//   - Observations persisted to disk per device + collective pool
//   - GET /api/adaptive-learning/history/:deviceId — observation history
//   - GET /api/adaptive-learning/collective-insights — cross-user patterns
//   - POST /api/adaptive-learning/sync — device recovery after reinstall
//   - Existing analyze/feedback logic unchanged (keyword + OpenAI modes)
//
// Requirements: Node.js 18+, optional `openai` package
// Storage: JSON files in ./data/ directory (auto-created)
// Port: env PORT or 8080
// =============================================================================

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const PORT = parseInt(process.env.PORT, 10) || 8080;
const DATA_DIR = path.resolve(__dirname, 'data');
const COLLECTIVE_DIR = path.join(DATA_DIR, '_collective');
const AI_ENABLED = process.env.AI_ENABLED === 'true';
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';

let openai = null;
if (AI_ENABLED && OPENAI_API_KEY) {
  try {
    const OpenAI = require('openai');
    openai = new OpenAI({ apiKey: OPENAI_API_KEY });
    console.log('[Hermes] OpenAI habilitado');
  } catch (err) {
    console.warn('[Hermes] openai package no disponible — modo keyword activo');
  }
}

// ---------------------------------------------------------------------------
// Ensure data directories
// ---------------------------------------------------------------------------
function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}
ensureDir(DATA_DIR);
ensureDir(COLLECTIVE_DIR);

// ---------------------------------------------------------------------------
// JSON Persistence helpers
// ---------------------------------------------------------------------------

/**
 * Read a JSON array file. Returns [] if not found or invalid.
 */
function readJsonArray(filePath) {
  try {
    if (!fs.existsSync(filePath)) return [];
    const raw = fs.readFileSync(filePath, 'utf8');
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/**
 * Write a JSON array to file (atomic via rename).
 */
function writeJsonArray(filePath, arr) {
  ensureDir(path.dirname(filePath));
  const tmp = filePath + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(arr, null, 2), 'utf8');
  fs.renameSync(tmp, filePath);
}

/**
 * Get the observations file path for a device.
 */
function deviceObsPath(deviceId) {
  // Sanitize deviceId to avoid directory traversal
  const safe = deviceId.replace(/[^a-zA-Z0-9_\-]/g, '_');
  return path.join(DATA_DIR, safe, 'observations.json');
}

function collectiveObsPath() {
  return path.join(COLLECTIVE_DIR, 'observations.json');
}

/**
 * Append an observation to both device-specific and collective files.
 */
function persistObservation(obs) {
  const deviceId = obs.deviceId;
  if (!deviceId) return;

  // Device file
  const devPath = deviceObsPath(deviceId);
  const devArr = readJsonArray(devPath);
  devArr.push(obs);
  writeJsonArray(devPath, devArr);

  // Collective file
  const colPath = collectiveObsPath();
  const colArr = readJsonArray(colPath);
  colArr.push(obs);
  writeJsonArray(colPath, colArr);
}

/**
 * Update an observation's feedback in both device and collective files.
 * Matches by observation id.
 */
function updateObservationFeedback(deviceId, observationId, feedback, status) {
  if (!deviceId) return;

  const updater = (arr) => {
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].id === observationId) {
        arr[i].feedback = feedback;
        if (status) arr[i].status = status;
        break;
      }
    }
    return arr;
  };

  // Device file
  const devPath = deviceObsPath(deviceId);
  writeJsonArray(devPath, updater(readJsonArray(devPath)));

  // Collective file
  const colPath = collectiveObsPath();
  writeJsonArray(colPath, updater(readJsonArray(colPath)));
}

// ---------------------------------------------------------------------------
// Scene mapping (matches Flutter SceneClass enum order)
// ---------------------------------------------------------------------------
const SCENE_NAMES = [
  'quiet',           // 0
  'speech',          // 1
  'speech_in_noise', // 2
  'noise',           // 3
  'music',           // 4
  'wind',            // 5
  'transport',       // 6
  'unknown',         // 7
];

function sceneIndexToName(idx) {
  return SCENE_NAMES[idx] || 'unknown';
}

// ---------------------------------------------------------------------------
// Keyword-based analysis (fallback when OpenAI unavailable)
// ---------------------------------------------------------------------------
function analyzeKeyword(body) {
  const text = (body.userText || '').toLowerCase();
  const scene = body.detectedScene || 0;
  const telemetry = body.telemetry || {};

  // Base suggestion: keep current settings
  const baseGains = telemetry.eqGains || Array(12).fill(0);
  let suggestedGains = [...baseGains];
  let suggestedNrLevel = telemetry.nrLevel != null ? telemetry.nrLevel : 1;
  let suggestedVolumeDb = telemetry.volumeDb != null ? telemetry.volumeDb : 0;
  let reasoning = '';
  let confidence = 0.5;

  // Simple keyword rules
  if (text.includes('ruido') || text.includes('ruid') || text.includes('noise')) {
    suggestedNrLevel = Math.min((telemetry.nrLevel || 1) + 1, 3);
    reasoning = 'Ruido reportado — se incrementa nivel de NR.';
    confidence = 0.6;
  } else if (text.includes('bajo') || text.includes('no escucho') || text.includes('quiet')) {
    suggestedVolumeDb = (telemetry.volumeDb || 0) + 3;
    suggestedGains = baseGains.map((g, i) => i >= 6 ? g + 2 : g + 1);
    reasoning = 'Volumen insuficiente — se aumenta ganancia global.';
    confidence = 0.55;
  } else if (text.includes('agudo') || text.includes('sharp') || text.includes('metálico')) {
    suggestedGains = baseGains.map((g, i) => i >= 8 ? g - 3 : g);
    reasoning = 'Agudos molestos — se reduce ganancia en bandas altas.';
    confidence = 0.55;
  } else if (text.includes('eco') || text.includes('reverb')) {
    suggestedNrLevel = Math.min((telemetry.nrLevel || 1) + 1, 3);
    suggestedGains = baseGains.map((g, i) => i <= 2 ? g - 2 : g);
    reasoning = 'Eco reportado — NR+ y reducción de graves.';
    confidence = 0.5;
  } else {
    reasoning = 'Sin patrón claro — se sugiere mantener configuración actual.';
    confidence = 0.3;
  }

  // Scene-based adjustments
  if (scene === 3 || scene === 2) { // noise or speech_in_noise
    suggestedNrLevel = Math.max(suggestedNrLevel, 2);
    if (!reasoning.includes('NR')) {
      reasoning += ' Escena ruidosa detectada — NR mínimo 2.';
    }
  }

  return {
    suggestedGains,
    suggestedNrLevel,
    suggestedVolumeDb,
    reasoning,
    confidence,
  };
}

// ---------------------------------------------------------------------------
// OpenAI-based analysis
// ---------------------------------------------------------------------------
async function analyzeWithAI(body) {
  if (!openai) return analyzeKeyword(body);

  const systemPrompt = `Eres Hermes, el motor de aprendizaje adaptativo de un audífono digital.
Recibes una observación del usuario sobre su entorno acústico junto con telemetría DSP del dispositivo.
Debes generar una sugerencia de ajuste DSP personalizada.

Responde SOLO con un JSON válido (sin markdown, sin explicación fuera del JSON):
{
  "suggestedGains": [12 floats, dB por banda EQ],
  "suggestedNrLevel": int 0-3,
  "suggestedVolumeDb": float,
  "reasoning": "explicación breve en español",
  "confidence": float 0.0-1.0
}

Reglas:
- Nunca sugierir cambios drásticos (máx ±6 dB por banda, ±4 dB volumen)
- Si no hay información suficiente, sugerir los valores actuales con confidence baja
- El NR va de 0 (off) a 3 (máximo)
- Las 12 bandas EQ están centradas en: 250,500,750,1k,1.5k,2k,2.5k,3k,3.5k,4k,5k,6k Hz`;

  const userMsg = JSON.stringify({
    userText: body.userText,
    telemetry: body.telemetry,
    detectedScene: body.detectedScene,
    sceneName: body.sceneName || sceneIndexToName(body.detectedScene || 0),
  });

  try {
    const response = await openai.chat.completions.create({
      model: process.env.OPENAI_MODEL || 'gpt-4o-mini',
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userMsg },
      ],
      temperature: 0.3,
      max_tokens: 500,
    });

    const content = response.choices[0]?.message?.content || '';
    // Strip markdown fences if present
    const clean = content.replace(/```json\s*/gi, '').replace(/```/g, '').trim();
    const parsed = JSON.parse(clean);

    return {
      suggestedGains: parsed.suggestedGains || Array(12).fill(0),
      suggestedNrLevel: parsed.suggestedNrLevel ?? 1,
      suggestedVolumeDb: parsed.suggestedVolumeDb ?? 0,
      reasoning: parsed.reasoning || '',
      confidence: parsed.confidence ?? 0.5,
    };
  } catch (err) {
    console.error('[Hermes] OpenAI error, fallback a keywords:', err.message);
    return analyzeKeyword(body);
  }
}

// ---------------------------------------------------------------------------
// Collective Insights computation
// ---------------------------------------------------------------------------
function computeCollectiveInsights() {
  const observations = readJsonArray(collectiveObsPath());

  // Group by detectedScene
  const byScene = {};
  for (const obs of observations) {
    const sceneKey = obs.detectedScene != null
      ? sceneIndexToName(obs.detectedScene)
      : 'unknown';
    if (!byScene[sceneKey]) byScene[sceneKey] = [];
    byScene[sceneKey].push(obs);
  }

  const insights = [];

  for (const [scene, sceneObs] of Object.entries(byScene)) {
    // Only consider observations that have suggestions and feedback
    const withFeedback = sceneObs.filter(o => o.suggestion && o.feedback != null);
    if (withFeedback.length === 0) continue;

    const positives = withFeedback.filter(o => o.feedback === true);
    const positiveRate = positives.length / withFeedback.length;

    // Find the most common suggestion among positives (by NR level + avg gains)
    let commonAdjustment = null;
    if (positives.length > 0) {
      // Average the suggestion parameters across positives
      const avgGains = Array(12).fill(0);
      let avgNr = 0;
      let avgVol = 0;

      for (const obs of positives) {
        const s = obs.suggestion;
        if (s.suggestedGains) {
          for (let i = 0; i < 12; i++) {
            avgGains[i] += (s.suggestedGains[i] || 0);
          }
        }
        avgNr += (s.suggestedNrLevel || 0);
        avgVol += (s.suggestedVolumeDb || 0);
      }

      const n = positives.length;
      commonAdjustment = {
        suggestedGains: avgGains.map(g => Math.round((g / n) * 10) / 10),
        suggestedNrLevel: Math.round(avgNr / n),
        suggestedVolumeDb: Math.round((avgVol / n) * 10) / 10,
      };
    }

    insights.push({
      scene,
      commonAdjustment,
      positiveRate: Math.round(positiveRate * 1000) / 1000,
      sampleSize: withFeedback.length,
    });
  }

  // Sort by sample size descending
  insights.sort((a, b) => b.sampleSize - a.sampleSize);
  return insights;
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => { data += chunk; });
    req.on('end', () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  });
  res.end(body);
}

function send404(res) {
  sendJson(res, 404, { error: 'Not found' });
}

function send400(res, msg) {
  sendJson(res, 400, { error: msg });
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

/**
 * POST /api/adaptive-learning/analyze
 * Receives observation, generates suggestion, persists to disk.
 */
async function handleAnalyze(req, res) {
  let body;
  try {
    body = await readBody(req);
  } catch {
    return send400(res, 'Invalid JSON body');
  }

  const deviceId = body.deviceId;
  if (!deviceId || typeof deviceId !== 'string') {
    return send400(res, 'deviceId is required');
  }

  // Generate suggestion (AI or keyword)
  let suggestion;
  if (openai) {
    suggestion = await analyzeWithAI(body);
  } else {
    suggestion = analyzeKeyword(body);
  }

  // Build observation record
  const observation = {
    id: body.observationId || Date.now(),
    timestamp: body.timestamp || new Date().toISOString(),
    deviceId,
    userText: body.userText || '',
    telemetry: body.telemetry || {},
    detectedScene: body.detectedScene != null ? body.detectedScene : 7,
    suggestion,
    status: 'suggestionReady',
    feedback: null,
  };

  // Persist to disk
  try {
    persistObservation(observation);
  } catch (err) {
    console.error('[Hermes] Persist error:', err.message);
    // Non-fatal — still return the suggestion
  }

  // Respond with the suggestion (backwards-compatible response format)
  sendJson(res, 200, suggestion);
}

/**
 * POST /api/adaptive-learning/feedback
 * Receives thumbs up/down, updates stored observation.
 */
async function handleFeedback(req, res) {
  let body;
  try {
    body = await readBody(req);
  } catch {
    return send400(res, 'Invalid JSON body');
  }

  const deviceId = body.deviceId;
  const observationId = body.observationId;
  const feedback = body.feedback; // true or false

  if (!deviceId || typeof deviceId !== 'string') {
    return send400(res, 'deviceId is required');
  }

  if (observationId == null) {
    return send400(res, 'observationId is required');
  }

  if (typeof feedback !== 'boolean') {
    return send400(res, 'feedback must be boolean');
  }

  // Determine status based on feedback
  const status = feedback ? 'applied' : 'dismissed';

  // Update in stored files
  try {
    updateObservationFeedback(deviceId, observationId, feedback, status);
  } catch (err) {
    console.error('[Hermes] Feedback persist error:', err.message);
  }

  sendJson(res, 200, { ok: true, feedback, status });
}

/**
 * GET /api/adaptive-learning/history/:deviceId
 * Returns full observation history for a device.
 */
function handleHistory(res, deviceId) {
  if (!deviceId) {
    return send400(res, 'deviceId is required');
  }

  const observations = readJsonArray(deviceObsPath(deviceId));
  sendJson(res, 200, {
    observations,
    count: observations.length,
  });
}

/**
 * GET /api/adaptive-learning/collective-insights
 * Returns aggregated cross-user learning insights.
 */
function handleCollectiveInsights(res) {
  const insights = computeCollectiveInsights();
  sendJson(res, 200, { insights });
}

/**
 * POST /api/adaptive-learning/sync
 * Device recovery — returns history + insights + autoApply recommendation.
 */
async function handleSync(req, res) {
  let body;
  try {
    body = await readBody(req);
  } catch {
    return send400(res, 'Invalid JSON body');
  }

  const deviceId = body.deviceId;
  if (!deviceId || typeof deviceId !== 'string') {
    return send400(res, 'deviceId is required');
  }

  const observations = readJsonArray(deviceObsPath(deviceId));
  const insights = computeCollectiveInsights();

  // autoApplyRecommended: true if >70% of feedbacks are positive
  const withFeedback = observations.filter(o => o.feedback != null);
  let autoApplyRecommended = false;
  if (withFeedback.length > 0) {
    const positives = withFeedback.filter(o => o.feedback === true);
    autoApplyRecommended = (positives.length / withFeedback.length) > 0.7;
  }

  sendJson(res, 200, {
    observations,
    autoApplyRecommended,
    insights,
  });
}

/**
 * GET /health
 */
function handleHealth(res) {
  sendJson(res, 200, {
    status: 'ok',
    version: '2.0.0',
    aiEnabled: openai !== null,
    timestamp: new Date().toISOString(),
    endpoints: [
      'POST /api/adaptive-learning/analyze',
      'POST /api/adaptive-learning/feedback',
      'GET  /api/adaptive-learning/history/:deviceId',
      'GET  /api/adaptive-learning/collective-insights',
      'POST /api/adaptive-learning/sync',
      'GET  /health',
    ],
  });
}

// ---------------------------------------------------------------------------
// HTTP Server + Router
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    return res.end();
  }

  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  try {
    // POST /api/adaptive-learning/analyze
    if (req.method === 'POST' && pathname === '/api/adaptive-learning/analyze') {
      return await handleAnalyze(req, res);
    }

    // POST /api/adaptive-learning/feedback
    if (req.method === 'POST' && pathname === '/api/adaptive-learning/feedback') {
      return await handleFeedback(req, res);
    }

    // POST /api/adaptive-learning/sync
    if (req.method === 'POST' && pathname === '/api/adaptive-learning/sync') {
      return await handleSync(req, res);
    }

    // GET /api/adaptive-learning/history/:deviceId
    const historyMatch = pathname.match(/^\/api\/adaptive-learning\/history\/([^/]+)$/);
    if (req.method === 'GET' && historyMatch) {
      return handleHistory(res, decodeURIComponent(historyMatch[1]));
    }

    // GET /api/adaptive-learning/collective-insights
    if (req.method === 'GET' && pathname === '/api/adaptive-learning/collective-insights') {
      return handleCollectiveInsights(res);
    }

    // GET /health
    if (req.method === 'GET' && (pathname === '/health' || pathname === '/')) {
      return handleHealth(res);
    }

    send404(res);
  } catch (err) {
    console.error('[Hermes] Unhandled error:', err);
    sendJson(res, 500, { error: 'Internal server error' });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[Hermes] Adaptive Learning Server v2.0 listening on :${PORT}`);
  console.log(`[Hermes] AI: ${openai ? 'OpenAI (' + (process.env.OPENAI_MODEL || 'gpt-4o-mini') + ')' : 'keyword mode'}`);
  console.log(`[Hermes] Data dir: ${DATA_DIR}`);
});
