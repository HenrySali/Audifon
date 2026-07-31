# AI Module — PSK Hearing Aid

Sistema de inteligencia artificial integrado al audífono digital.

## Setup

```bash
cd ai/
npm install
npm run build-kb   # Indexar documentación
```

Configurar API key de OpenAI:
```bash
export OPENAI_API_KEY=sk-...
```

> Sin API key, las features funcionan en modo local (sin generación de texto AI).

## Features

| # | Feature | Archivo | Requiere OpenAI |
|---|---------|---------|-----------------|
| 1 | Asistente de Fitting | `fitting-assistant/` | Opcional |
| 2 | Auto-Diagnóstico | `diagnostics/` | Opcional |
| 3 | Chatbot Técnico | `chatbot/` | Sí |
| 4 | Reportes Clínicos | `reports/` | Opcional |
| 5 | RAG Desarrollo | `rag/` | Opcional |
| 6 | Clasificador ML | `environment-ml/` | No |

## Uso Rápido

```javascript
const { createAISystem } = require('./ai');
const ai = createAISystem({ apiKey: process.env.OPENAI_API_KEY });

// 1. Prescribir desde audiograma
const result = await ai.fitting.prescribe(
    { frequencies: [250,500,1000,2000,4000,8000], thresholds: [15,20,30,45,55,60] },
    { age: 6, isChild: true }
);
console.log(result.config.eq.gains);  // Ganancias EQ por banda
console.log(result.explanation);       // Explicación en lenguaje natural

// 2. Diagnosticar
const diagnosis = await ai.diagnostics.analyze({
    baseline: { gains: [0,0,0,0,0,0,0,0,0,0,0,0] },
    current: { gains: [0,0,-1,-2,-4,-5,-6,-7,-5,-4,-3,-2] }
});
console.log(diagnosis.patterns);       // Patrones detectados
console.log(diagnosis.recommendations);// Qué hacer

// 3. Chatbot
const answer = await ai.chatbot.ask("¿Qué es el WDRC?");
console.log(answer.answer);

// 4. Reporte
const report = await ai.reports.generate({
    patient: { name: 'Juan', age: 7 },
    audiogram: { frequencies: [500,1000,2000,4000], thresholds: [25,35,50,60] },
    dspConfig: result.config,
    clinician: { name: 'Dra. García', license: 'MP-1234' }
});
console.log(report.markdown);

// 5. RAG
const dev = await ai.rag.query("¿Cómo funciona el crossfade?");
console.log(dev.answer);

// 6. Clasificador de entorno
const env = ai.environment.predict({
    rmsLevel: -35, spectralCentroid: 2000, spectralFlux: 0.3,
    zeroCrossRate: 0.15, lowBandEnergy: 0.3, midBandEnergy: 0.4,
    highBandEnergy: 0.3, modulationRate: 4, snrEstimate: 15, peakiness: 5
});
console.log(env.class, env.confidence);
```

## Arquitectura

```
ai/
├── index.js                 ← Entry point, createAISystem()
├── config.js                ← Configuración central (clínica + OpenAI)
├── knowledge-base/
│   ├── build-index.js       ← Indexador de documentación
│   ├── knowledge-index.json ← Índice generado (metadata)
│   └── knowledge-content.json ← Contenido para RAG
├── fitting-assistant/
│   └── index.js             ← Prescripción NAL-NL2 + AI explanation
├── diagnostics/
│   └── index.js             ← Análisis de calibración + patrones
├── chatbot/
│   └── index.js             ← RAG chatbot para audiólogos
├── reports/
│   └── index.js             ← Generador de reportes Markdown
├── rag/
│   └── index.js             ← RAG para desarrolladores
└── environment-ml/
    └── index.js             ← Clasificador con aprendizaje online
```
