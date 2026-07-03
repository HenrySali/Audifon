# Hermes Server Upgrade — v2.0 (Collective Learning)

## Descripción

Servidor actualizado de Hermes Adaptive Learning con:
- **Persistencia en disco** — observaciones almacenadas como JSON por dispositivo
- **Historial por dispositivo** — endpoint para consultar observaciones previas
- **Aprendizaje colectivo** — insights agregados de todos los usuarios
- **Sync para reinstalación** — recuperación de datos al reinstalar la app

## Endpoints

| Método | Ruta | Descripción |
|--------|------|-------------|
| POST | `/api/adaptive-learning/analyze` | Analiza observación, genera sugerencia, persiste |
| POST | `/api/adaptive-learning/feedback` | Registra thumbs up/down en la observación |
| GET | `/api/adaptive-learning/history/:deviceId` | Historial de observaciones del dispositivo |
| GET | `/api/adaptive-learning/collective-insights` | Insights agregados cross-user |
| POST | `/api/adaptive-learning/sync` | Recuperación post-reinstalación |
| GET | `/health` | Health check con info del servidor |

## Cambios respecto a v1

1. **analyze** — ahora requiere `deviceId` en el body; persiste cada observación + sugerencia en `data/<deviceId>/observations.json` y `data/_collective/observations.json`
2. **feedback** — ahora requiere `deviceId`; actualiza el feedback en ambos archivos
3. **history** — NUEVO: devuelve `{ observations: [...], count: N }`
4. **collective-insights** — NUEVO: agrupa por escena y calcula la sugerencia más exitosa
5. **sync** — NUEVO: devuelve historial + insights + recomendación de autoApply

## Despliegue en VPS (149.50.137.2)

### Pre-requisitos
- Node.js 18+ instalado
- pm2 instalado globalmente (`npm i -g pm2`)
- openai package instalado en el directorio (`npm i openai`)

### Pasos

```bash
# 1. Conectar al VPS
ssh root@149.50.137.2

# 2. Detener el servidor actual
pm2 stop hermes-learning

# 3. Backup del server actual
cp "/var/www/OirPro K/adaptive-learning/server.js" \
   "/var/www/OirPro K/adaptive-learning/server.js.bak.$(date +%Y%m%d)"

# 4. Copiar el nuevo server (desde local al VPS)
# Desde tu máquina local:
scp server-patch.js root@149.50.137.2:"/var/www/OirPro K/adaptive-learning/server.js"

# 5. En el VPS, crear directorio de datos si no existe
mkdir -p "/var/www/OirPro K/adaptive-learning/data/_collective"

# 6. Verificar variables de entorno en ecosystem
pm2 show hermes-learning
# Debe tener: PORT=8080, AI_ENABLED=true, OPENAI_API_KEY=sk-...

# 7. Reiniciar con pm2
pm2 restart hermes-learning

# 8. Verificar logs
pm2 logs hermes-learning --lines 20

# 9. Test rápido
curl http://localhost:8080/health
```

### Alternativa: Si no usas pm2 ecosystem file

```bash
cd "/var/www/OirPro K/adaptive-learning"
PORT=8080 AI_ENABLED=true OPENAI_API_KEY=sk-... pm2 start server.js --name hermes-learning
pm2 save
```

## Estructura de datos

```
/var/www/OirPro K/adaptive-learning/
├── server.js              ← este archivo (server-patch.js)
├── node_modules/
│   └── openai/
├── data/
│   ├── _collective/
│   │   └── observations.json    ← todas las observaciones pooled
│   ├── abc123/
│   │   └── observations.json    ← observaciones del device abc123
│   └── def456/
│       └── observations.json
└── package.json (opcional)
```

### Formato de observación almacenada

```json
{
  "id": 1234567890,
  "timestamp": "2026-07-01T12:00:00.000Z",
  "deviceId": "abc123",
  "userText": "supermercado ruidoso",
  "telemetry": {
    "inputLevelDb": -25.3,
    "outputLevelDb": -18.1,
    "nrLevel": 1,
    "eqGains": [0,0,0,0,0,0,0,0,0,0,0,0],
    "volumeDb": 0
  },
  "detectedScene": 3,
  "suggestion": {
    "suggestedGains": [0,0,0,0,0,0,0,0,0,0,0,0],
    "suggestedNrLevel": 2,
    "suggestedVolumeDb": 0,
    "reasoning": "Ruido reportado — se incrementa NR.",
    "confidence": 0.6
  },
  "status": "suggestionReady",
  "feedback": null
}
```

## Compatibilidad

- **Apps existentes** (Audifon técnico/usuario): Los endpoints analyze y feedback mantienen la misma respuesta — son backwards compatible. El campo `deviceId` es nuevo pero no rompe clients viejos (el server usa `Date.now()` como fallback si no hay observationId).
- **Sin OpenAI**: El server funciona en modo keyword si `AI_ENABLED` no está en true o si el package `openai` no está instalado.
- **Sin datos previos**: Todos los endpoints de lectura devuelven arrays vacíos si no hay datos.

## Testing manual

```bash
# Analyze
curl -X POST http://149.50.137.2:8080/api/adaptive-learning/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "test-device-001",
    "userText": "mucho ruido en el supermercado",
    "telemetry": {"inputLevelDb": -25, "nrLevel": 1, "eqGains": [0,0,0,0,0,0,0,0,0,0,0,0], "volumeDb": 0},
    "detectedScene": 3,
    "sceneName": "noise"
  }'

# Feedback
curl -X POST http://149.50.137.2:8080/api/adaptive-learning/feedback \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "test-device-001",
    "observationId": 1234567890,
    "feedback": true
  }'

# History
curl http://149.50.137.2:8080/api/adaptive-learning/history/test-device-001

# Collective Insights
curl http://149.50.137.2:8080/api/adaptive-learning/collective-insights

# Sync
curl -X POST http://149.50.137.2:8080/api/adaptive-learning/sync \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "test-device-001"}'
```

## Rollback

Si algo falla:

```bash
ssh root@149.50.137.2
cp "/var/www/OirPro K/adaptive-learning/server.js.bak.YYYYMMDD" \
   "/var/www/OirPro K/adaptive-learning/server.js"
pm2 restart hermes-learning
```

Los datos en `data/` se preservan — no se pierden con el rollback.
