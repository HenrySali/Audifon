/**
 * Auto-Diagnóstico con Explicación AI
 * 
 * Interpreta resultados de calibración ANSI S3.22, detecta problemas,
 * y genera explicaciones comprensibles para el usuario/audiólogo.
 * 
 * Uso:
 *   const { DiagnosticsEngine } = require('./diagnostics');
 *   const engine = new DiagnosticsEngine();
 *   const report = await engine.analyze(calibrationData);
 */

const config = require('../config');

class DiagnosticsEngine {
    constructor(openaiClient = null) {
        this.openai = openaiClient;
    }

    /**
     * Analiza datos de calibración y genera diagnóstico
     * @param {Object} calibrationData - Datos de la última calibración
     * @returns {Object} Diagnóstico con explicación y recomendaciones
     */
    async analyze(calibrationData) {
        const {
            baseline,           // Medición de fábrica
            current,            // Medición actual
            history = [],       // Historial de mediciones
            deviceAge = 0,      // Días desde fabricación
            batteryLevel = 100  // Nivel de batería actual
        } = calibrationData;

        // 1. Calcular Índice de Degradación (DI) por banda
        const degradation = this._computeDegradation(baseline, current);

        // 2. Detectar patrones de fallo
        const patterns = this._detectPatterns(degradation, history);

        // 3. Evaluar severidad
        const severity = this._evaluateSeverity(degradation);

        // 4. Generar recomendaciones
        const recommendations = this._generateRecommendations(patterns, severity, deviceAge);

        // 5. Generar explicación
        let explanation;
        if (this.openai) {
            try {
                explanation = await this._generateAIExplanation(degradation, patterns, severity, recommendations);
            } catch (err) {
                explanation = this._generateLocalExplanation(degradation, patterns, severity, recommendations);
            }
        } else {
            explanation = this._generateLocalExplanation(degradation, patterns, severity, recommendations);
        }

        return {
            timestamp: new Date().toISOString(),
            degradation: degradation,
            patterns: patterns,
            severity: severity,
            recommendations: recommendations,
            explanation: explanation,
            compensation: this._computeCompensation(degradation),
            needsService: severity.level === 'critical'
        };
    }

    /**
     * Calcula degradación por banda
     */
    _computeDegradation(baseline, current) {
        const frequencies = config.clinical.eqFrequencies;
        const bands = [];
        let totalDI = 0;

        for (let i = 0; i < frequencies.length; i++) {
            const baselineGain = baseline.gains ? baseline.gains[i] : 0;
            const currentGain = current.gains ? current.gains[i] : 0;
            const deviation = currentGain - baselineGain;

            bands.push({
                frequency: frequencies[i],
                baseline: baselineGain,
                current: currentGain,
                deviation: deviation,
                deviationAbs: Math.abs(deviation)
            });

            totalDI += Math.abs(deviation);
        }

        return {
            bands: bands,
            degradationIndex: Math.round(totalDI * 100) / 100,
            maxDeviation: Math.max(...bands.map(b => b.deviationAbs)),
            affectedBands: bands.filter(b => b.deviationAbs > 3).length
        };
    }

    /**
     * Detecta patrones conocidos de fallo
     */
    _detectPatterns(degradation, history) {
        const patterns = [];

        // Patrón 1: Pérdida en altas frecuencias → cerumen/humedad en receptor
        const highFreqLoss = degradation.bands
            .filter(b => b.frequency >= 3000 && b.deviation < -3);
        if (highFreqLoss.length >= 3) {
            patterns.push({
                id: 'high_freq_loss',
                name: 'Pérdida en frecuencias altas',
                confidence: 0.85,
                cause: 'Posible acumulación de cerumen o humedad en el receptor',
                action: 'Limpiar tubo y receptor con herramienta de limpieza'
            });
        }

        // Patrón 2: Pérdida uniforme en todas las bandas → batería baja o receptor dañado
        const uniformLoss = degradation.bands.every(b => b.deviation < -2 && b.deviation > -8);
        if (uniformLoss && degradation.affectedBands >= 8) {
            patterns.push({
                id: 'uniform_loss',
                name: 'Pérdida uniforme de ganancia',
                confidence: 0.7,
                cause: 'Receptor debilitado o batería insuficiente',
                action: 'Verificar batería. Si persiste, consultar servicio técnico'
            });
        }

        // Patrón 3: Pico en una banda → resonancia/feedback
        const peakBands = degradation.bands.filter(b => b.deviation > 5);
        if (peakBands.length === 1 || peakBands.length === 2) {
            patterns.push({
                id: 'resonance_peak',
                name: 'Pico de resonancia',
                confidence: 0.6,
                cause: 'Posible feedback acústico o molde mal ajustado',
                action: 'Verificar ajuste del molde. Considerar reducir ganancia en la banda afectada'
            });
        }

        // Patrón 4: Degradación progresiva (comparar con historial)
        if (history.length >= 3) {
            const diTrend = history.map(h => h.degradationIndex || 0);
            const isProgressive = diTrend.every((val, i) => i === 0 || val >= diTrend[i - 1] - 1);
            if (isProgressive && degradation.degradationIndex > 15) {
                patterns.push({
                    id: 'progressive_degradation',
                    name: 'Degradación progresiva',
                    confidence: 0.9,
                    cause: 'Desgaste natural del receptor o micrófono',
                    action: 'Programar revisión técnica. Considerar reemplazo de receptor'
                });
            }
        }

        // Patrón 5: Sin degradación significativa
        if (patterns.length === 0 && degradation.degradationIndex < 5) {
            patterns.push({
                id: 'normal',
                name: 'Funcionamiento normal',
                confidence: 0.95,
                cause: 'El dispositivo opera dentro de especificaciones',
                action: 'Ninguna acción requerida'
            });
        }

        return patterns;
    }

    /**
     * Evalúa severidad del diagnóstico
     */
    _evaluateSeverity(degradation) {
        const di = degradation.degradationIndex;
        const maxDev = degradation.maxDeviation;

        if (di < 5 && maxDev < 3) {
            return { level: 'normal', color: 'green', message: 'Dispositivo funcionando correctamente' };
        } else if (di < 15 && maxDev < 6) {
            return { level: 'warning', color: 'yellow', message: 'Degradación leve detectada — monitorear' };
        } else if (di < 30 && maxDev < 10) {
            return { level: 'attention', color: 'orange', message: 'Degradación moderada — acción recomendada' };
        } else {
            return { level: 'critical', color: 'red', message: 'Degradación severa — servicio técnico necesario' };
        }
    }

    /**
     * Genera recomendaciones específicas
     */
    _generateRecommendations(patterns, severity, deviceAge) {
        const recs = [];

        // Recomendaciones basadas en patrones
        for (const pattern of patterns) {
            if (pattern.id !== 'normal') {
                recs.push({
                    priority: severity.level === 'critical' ? 'alta' : 'media',
                    action: pattern.action,
                    reason: pattern.cause
                });
            }
        }

        // Recomendaciones basadas en edad del dispositivo
        if (deviceAge > 365) {
            recs.push({
                priority: 'baja',
                action: 'Considerar revisión anual completa',
                reason: `El dispositivo tiene ${Math.round(deviceAge / 30)} meses de uso`
            });
        }

        // Si no hay recomendaciones, indicar que todo está bien
        if (recs.length === 0) {
            recs.push({
                priority: 'info',
                action: 'Continuar uso normal. Próxima calibración automática programada.',
                reason: 'Todos los parámetros dentro de especificación'
            });
        }

        return recs;
    }

    /**
     * Calcula curva de compensación
     */
    _computeCompensation(degradation) {
        const maxCompensation = 10; // Cap de 10 dB según spec
        return degradation.bands.map(band => {
            // Compensar la desviación (invertir el signo)
            const compensation = -band.deviation;
            // Limitar a ±10 dB
            return Math.max(-maxCompensation, Math.min(maxCompensation, Math.round(compensation * 10) / 10));
        });
    }

    /**
     * Explicación local (sin AI)
     */
    _generateLocalExplanation(degradation, patterns, severity, recommendations) {
        const mainPattern = patterns[0] || { name: 'Sin patrón identificado' };
        return {
            title: `Diagnóstico: ${severity.message}`,
            body: `Se detectó un Índice de Degradación de ${degradation.degradationIndex.toFixed(1)} ` +
                `(${degradation.affectedBands} bandas afectadas). ` +
                `Patrón principal: ${mainPattern.name}. ` +
                `${mainPattern.cause || ''}`,
            recommendations: recommendations.map(r => `[${r.priority.toUpperCase()}] ${r.action}`),
            aiGenerated: false
        };
    }

    /**
     * Explicación con AI
     */
    async _generateAIExplanation(degradation, patterns, severity, recommendations) {
        const prompt = `Eres un técnico de audífonos explicando un diagnóstico a un padre/madre.
El audífono de su hijo muestra:
- Índice de degradación: ${degradation.degradationIndex.toFixed(1)} (${severity.level})
- Bandas afectadas: ${degradation.affectedBands} de 12
- Desviación máxima: ${degradation.maxDeviation.toFixed(1)} dB
- Patrón detectado: ${patterns.map(p => p.name).join(', ')}
- Causa probable: ${patterns.map(p => p.cause).join('. ')}

Explica en español simple (no técnico) qué significa esto y qué deben hacer.
Máximo 150 palabras. Sé tranquilizador si no es grave.`;

        const response = await this.openai.chat.completions.create({
            model: config.openai.model,
            messages: [{ role: 'user', content: prompt }],
            temperature: 0.4,
            max_tokens: 300
        });

        return {
            title: `Diagnóstico: ${severity.message}`,
            body: response.choices[0].message.content,
            recommendations: recommendations.map(r => `[${r.priority.toUpperCase()}] ${r.action}`),
            aiGenerated: true
        };
    }
}

module.exports = { DiagnosticsEngine };
