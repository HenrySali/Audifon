/**
 * Generador de Reportes Clínicos
 * 
 * Genera reportes profesionales en Markdown/HTML después de una sesión
 * de fitting, incluyendo audiograma, configuración, justificación y métricas.
 * 
 * Uso:
 *   const { ReportGenerator } = require('./reports');
 *   const gen = new ReportGenerator(openaiClient);
 *   const report = await gen.generate(sessionData);
 */

const config = require('../config');

class ReportGenerator {
    constructor(openaiClient = null) {
        this.openai = openaiClient;
    }

    /**
     * Genera reporte completo de sesión de fitting
     * @param {Object} session - Datos de la sesión
     * @returns {Object} Reporte en Markdown y datos estructurados
     */
    async generate(session) {
        const {
            patient,        // { name, age, id, diagnosis }
            audiogram,      // { frequencies, thresholds }
            dspConfig,      // Configuración DSP aplicada
            calibration,    // Datos de calibración (opcional)
            clinician,      // { name, license }
            date = new Date().toISOString(),
            notes = ''
        } = session;

        // 1. Calcular métricas del fitting
        const metrics = this._computeMetrics(audiogram, dspConfig);

        // 2. Generar secciones del reporte
        const sections = {
            header: this._generateHeader(patient, clinician, date),
            audiogram: this._generateAudiogramSection(audiogram),
            prescription: this._generatePrescriptionSection(dspConfig, metrics),
            wdrc: this._generateWdrcSection(dspConfig.wdrc),
            safety: this._generateSafetySection(dspConfig, metrics),
            calibration: calibration ? this._generateCalibrationSection(calibration) : '',
            recommendations: '',
            notes: notes ? `## Notas Clínicas\n\n${notes}\n` : ''
        };

        // 3. Generar recomendaciones con AI (si disponible)
        if (this.openai) {
            try {
                sections.recommendations = await this._generateAIRecommendations(session, metrics);
            } catch (err) {
                sections.recommendations = this._generateLocalRecommendations(metrics);
            }
        } else {
            sections.recommendations = this._generateLocalRecommendations(metrics);
        }

        // 4. Ensamblar reporte
        const markdown = this._assembleReport(sections);

        return {
            markdown: markdown,
            metrics: metrics,
            generatedAt: date,
            patient: patient,
            format: 'markdown'
        };
    }

    _generateHeader(patient, clinician, date) {
        const dateStr = new Date(date).toLocaleDateString('es-ES', {
            year: 'numeric', month: 'long', day: 'numeric'
        });

        return `# Reporte de Fitting — Audífono Digital PSK

| Campo | Valor |
|-------|-------|
| **Paciente** | ${patient.name || 'N/A'} |
| **Edad** | ${patient.age || 'N/A'} años |
| **ID** | ${patient.id || 'N/A'} |
| **Diagnóstico** | ${patient.diagnosis || 'Hipoacusia'} |
| **Profesional** | ${clinician?.name || 'N/A'} (${clinician?.license || ''}) |
| **Fecha** | ${dateStr} |
| **Prescripción** | NAL-NL2 ${patient.age < 18 ? '(pediátrico)' : '(adulto)'} |
`;
    }

    _generateAudiogramSection(audiogram) {
        let section = `## Audiograma\n\n`;
        section += `| Frecuencia (Hz) | Umbral (dB HL) | Clasificación |\n`;
        section += `|-----------------|----------------|---------------|\n`;

        for (let i = 0; i < audiogram.frequencies.length; i++) {
            const freq = audiogram.frequencies[i];
            const hl = audiogram.thresholds[i];
            const classification = this._classifyHL(hl);
            section += `| ${freq} | ${hl} | ${classification} |\n`;
        }

        const pta = this._computePTA(audiogram);
        section += `\n**PTA (500-1k-2k-4k):** ${pta.toFixed(0)} dB HL — ${this._classifyHL(pta)}\n`;

        return section;
    }

    _generatePrescriptionSection(dspConfig, metrics) {
        let section = `## Prescripción EQ (12 Bandas)\n\n`;
        section += `| Banda | Frecuencia | Ganancia | Nota |\n`;
        section += `|-------|-----------|----------|------|\n`;

        const freqs = config.clinical.eqFrequencies;
        for (let i = 0; i < freqs.length; i++) {
            const gain = dspConfig.eq.gains[i];
            const note = gain > 20 ? '⚠ Alta' : gain > 10 ? 'Moderada' : 'Leve';
            section += `| ${i + 1} | ${freqs[i]} Hz | +${gain.toFixed(1)} dB | ${note} |\n`;
        }

        section += `\n**Ganancia máxima:** ${metrics.maxGain.toFixed(1)} dB @ ${metrics.maxGainFreq} Hz\n`;
        section += `**Ganancia promedio:** ${metrics.avgGain.toFixed(1)} dB\n`;

        return section;
    }

    _generateWdrcSection(wdrc) {
        return `## Compresión Dinámica (WDRC)

| Parámetro | Valor | Descripción |
|-----------|-------|-------------|
| Expansión Knee | ${wdrc.expansionKnee} dB SPL | Bajo este nivel → atenuar (ruido) |
| Expansión Ratio | ${wdrc.expansionRatio}:1 | Tasa de atenuación en silencio |
| Compresión Knee | ${wdrc.compressionKnee} dB SPL | Sobre este nivel → comprimir |
| Compresión Ratio | ${wdrc.compressionRatio}:1 | Tasa de compresión |
| Attack | ${wdrc.attackMs} ms | Velocidad de reacción a sonidos fuertes |
| Release | ${wdrc.releaseMs} ms | Velocidad de recuperación |

**Región lineal:** ${wdrc.expansionKnee}–${wdrc.compressionKnee} dB SPL (ganancia completa sin modificación)
`;
    }

    _generateSafetySection(dspConfig, metrics) {
        const mpo = dspConfig.mpo;
        return `## Seguridad

| Parámetro | Valor | Límite | Estado |
|-----------|-------|--------|--------|
| MPO | ${mpo.threshold_dBSPL} dB SPL | ≤ 110 dB SPL | ${mpo.threshold_dBSPL <= 110 ? '✅' : '⚠️'} |
| Ganancia máx/banda | ${metrics.maxGain.toFixed(1)} dB | ≤ 30 dB | ${metrics.maxGain <= 30 ? '✅' : '⚠️'} |
| Ganancia total est. | ${metrics.estimatedTotalGain.toFixed(1)} dB | ≤ 40 dB | ${metrics.estimatedTotalGain <= 40 ? '✅' : '⚠️'} |
| NR gain floor | ${dspConfig.nr.gainFloor} | ≥ 0.18 | ${dspConfig.nr.gainFloor >= 0.18 ? '✅' : '⚠️'} |

**MPO Attack:** ${mpo.attackMs} ms | **MPO Release:** ${mpo.releaseMs} ms
`;
    }

    _generateCalibrationSection(calibration) {
        return `## Estado de Calibración

| Métrica | Valor |
|---------|-------|
| Índice de Degradación | ${calibration.degradationIndex?.toFixed(1) || 'N/A'} |
| Bandas afectadas | ${calibration.affectedBands || 0} / 12 |
| Última calibración | ${calibration.lastDate || 'N/A'} |
| Estado | ${calibration.status || 'Normal'} |
`;
    }

    _generateLocalRecommendations(metrics) {
        const recs = ['## Recomendaciones\n'];

        if (metrics.maxGain > 20) {
            recs.push('- Monitorear confort del paciente con ganancias altas (>20 dB)');
        }
        if (metrics.estimatedTotalGain > 30) {
            recs.push('- Verificar que el MPO limita correctamente con señales fuertes');
        }
        recs.push('- Control en 2 semanas para ajuste fino');
        recs.push('- Verificar adaptación del molde (feedback)');
        recs.push('- Próxima calibración automática programada');

        return recs.join('\n');
    }

    async _generateAIRecommendations(session, metrics) {
        const prompt = `Eres un audiólogo senior. Genera 4-5 recomendaciones de seguimiento para este fitting:
- Paciente: ${session.patient.age} años, ${session.patient.diagnosis || 'hipoacusia'}
- PTA: ${this._computePTA(session.audiogram).toFixed(0)} dB HL
- Ganancia máxima prescrita: ${metrics.maxGain.toFixed(1)} dB
- MPO: ${session.dspConfig.mpo.threshold_dBSPL} dB SPL
- CR: ${session.dspConfig.wdrc.compressionRatio}:1

Formato: lista con viñetas, español, profesional pero conciso. Máximo 100 palabras.`;

        const response = await this.openai.chat.completions.create({
            model: config.openai.model,
            messages: [{ role: 'user', content: prompt }],
            temperature: 0.4,
            max_tokens: 300
        });

        return `## Recomendaciones\n\n${response.choices[0].message.content}`;
    }

    _assembleReport(sections) {
        return [
            sections.header,
            sections.audiogram,
            sections.prescription,
            sections.wdrc,
            sections.safety,
            sections.calibration,
            sections.recommendations,
            sections.notes,
            `---\n*Reporte generado automáticamente por PSK Hearing Aid AI System*`
        ].filter(Boolean).join('\n\n');
    }

    _computeMetrics(audiogram, dspConfig) {
        const gains = dspConfig.eq.gains;
        const maxGain = Math.max(...gains);
        const maxGainIdx = gains.indexOf(maxGain);
        const freqs = config.clinical.eqFrequencies;

        return {
            maxGain: maxGain,
            maxGainFreq: freqs[maxGainIdx],
            avgGain: gains.reduce((a, b) => a + b, 0) / gains.length,
            estimatedTotalGain: maxGain + (dspConfig.volume?.masterGain || 0),
            pta: this._computePTA(audiogram)
        };
    }

    _computePTA(audiogram) {
        const ptaFreqs = [500, 1000, 2000, 4000];
        let sum = 0, count = 0;
        for (const freq of ptaFreqs) {
            const idx = audiogram.frequencies.indexOf(freq);
            if (idx >= 0) {
                sum += audiogram.thresholds[idx];
                count++;
            }
        }
        return count > 0 ? sum / count : 0;
    }

    _classifyHL(hl) {
        if (hl <= 15) return 'Normal';
        if (hl <= 25) return 'Leve';
        if (hl <= 40) return 'Leve-Moderada';
        if (hl <= 55) return 'Moderada';
        if (hl <= 70) return 'Moderada-Severa';
        if (hl <= 90) return 'Severa';
        return 'Profunda';
    }
}

module.exports = { ReportGenerator };
