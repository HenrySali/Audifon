/**
 * Asistente de Fitting Inteligente
 * 
 * Genera configuración DSP óptima a partir del audiograma del paciente.
 * Implementa NAL-NL2 con ajustes pediátricos y genera explicaciones
 * en lenguaje natural usando AI.
 * 
 * Uso:
 *   const { FittingAssistant } = require('./fitting-assistant');
 *   const assistant = new FittingAssistant();
 *   const result = await assistant.prescribe(audiogram, patientProfile);
 */

const config = require('../config');

class FittingAssistant {
    constructor(openaiClient = null) {
        this.openai = openaiClient;
        this.nalTable = config.nalNL2.gainTable;
        this.nalFreqs = config.nalNL2.frequencies;
        this.eqFreqs = config.clinical.eqFrequencies;
        this.safety = config.clinical.safety;
    }

    /**
     * Genera prescripción completa desde audiograma
     * @param {Object} audiogram - { frequencies: [250..8000], thresholds: [dB HL por freq] }
     * @param {Object} patient - { age: number, isChild: boolean, experience: 'new'|'experienced' }
     * @returns {Object} Configuración DSP completa con explicación
     */
    async prescribe(audiogram, patient = {}) {
        const { age = 10, isChild = true, experience = 'new' } = patient;

        // 1. Calcular ganancia NAL-NL2 por frecuencia
        const nalGains = this._computeNalNL2Gains(audiogram, isChild);

        // 2. Interpolar a las 12 bandas del EQ
        const eqGains = this._interpolateToEqBands(nalGains);

        // 3. Calcular parámetros WDRC
        const wdrc = this._computeWdrcParams(audiogram, eqGains);

        // 4. Calcular MPO seguro
        const mpo = this._computeMPO(audiogram, isChild);

        // 5. Determinar NR y AFC
        const nr = this._computeNR(audiogram);
        const afc = { enabled: true, mu: 0.005, taps: 64 };

        // 6. Aplicar RECD si es niño
        const recd = this._getRECD(age);

        // 7. Construir configuración completa
        const dspConfig = {
            eq: {
                frequencies: this.eqFreqs,
                gains: eqGains.map(g => Math.min(g, this.safety.maxGainPerBand_dB)),
                q: 1.41 // Q por defecto para peaking EQ
            },
            wdrc: wdrc,
            mpo: mpo,
            nr: nr,
            afc: afc,
            volume: { masterGain: 0 },
            recd: recd,
            metadata: {
                prescription: 'NAL-NL2',
                patientAge: age,
                isChild: isChild,
                experience: experience,
                generatedAt: new Date().toISOString()
            }
        };

        // 8. Validar seguridad
        const safetyCheck = this._validateSafety(dspConfig);

        // 9. Generar explicación con AI (si disponible)
        let explanation = this._generateLocalExplanation(audiogram, dspConfig, patient);
        if (this.openai) {
            try {
                explanation = await this._generateAIExplanation(audiogram, dspConfig, patient);
            } catch (err) {
                // Fallback a explicación local
            }
        }

        return {
            config: dspConfig,
            safety: safetyCheck,
            explanation: explanation,
            audiogram: audiogram
        };
    }

    /**
     * Calcula ganancias NAL-NL2 para las frecuencias de la tabla
     */
    _computeNalNL2Gains(audiogram, isChild) {
        const gains = [];
        for (let i = 0; i < this.nalFreqs.length; i++) {
            const freq = this.nalFreqs[i];
            const hl = this._getThresholdAtFreq(audiogram, freq);
            const gain = this._interpolateNalGain(hl, i);
            // Ajuste pediátrico
            const pediatricAdj = isChild ? config.nalNL2.pediatricBoost : 0;
            gains.push(gain + pediatricAdj);
        }
        return gains;
    }

    /**
     * Interpola ganancia NAL-NL2 para un HL dado
     */
    _interpolateNalGain(hl, freqIndex) {
        const hlClamped = Math.max(20, Math.min(80, hl));
        const hlLow = Math.floor(hlClamped / 10) * 10;
        const hlHigh = Math.ceil(hlClamped / 10) * 10;

        if (hlLow === hlHigh || !this.nalTable[hlHigh]) {
            return (this.nalTable[hlLow] || this.nalTable[20])[freqIndex] || 0;
        }

        const gainLow = this.nalTable[hlLow][freqIndex];
        const gainHigh = this.nalTable[hlHigh][freqIndex];
        const fraction = (hlClamped - hlLow) / 10;
        return gainLow + fraction * (gainHigh - gainLow);
    }

    /**
     * Obtiene el threshold del audiograma para una frecuencia dada
     */
    _getThresholdAtFreq(audiogram, targetFreq) {
        const { frequencies, thresholds } = audiogram;
        const idx = frequencies.indexOf(targetFreq);
        if (idx >= 0) return thresholds[idx];

        // Interpolar entre frecuencias adyacentes
        for (let i = 0; i < frequencies.length - 1; i++) {
            if (frequencies[i] <= targetFreq && frequencies[i + 1] >= targetFreq) {
                const ratio = (targetFreq - frequencies[i]) / (frequencies[i + 1] - frequencies[i]);
                return thresholds[i] + ratio * (thresholds[i + 1] - thresholds[i]);
            }
        }
        return thresholds[thresholds.length - 1]; // Extrapolar último valor
    }

    /**
     * Interpola las 8 ganancias NAL a las 12 bandas del EQ
     */
    _interpolateToEqBands(nalGains) {
        const eqGains = [];
        for (const eqFreq of this.eqFreqs) {
            // Encontrar las dos frecuencias NAL más cercanas
            let lowIdx = 0, highIdx = 0;
            for (let i = 0; i < this.nalFreqs.length - 1; i++) {
                if (this.nalFreqs[i] <= eqFreq && this.nalFreqs[i + 1] >= eqFreq) {
                    lowIdx = i;
                    highIdx = i + 1;
                    break;
                }
                if (eqFreq > this.nalFreqs[this.nalFreqs.length - 1]) {
                    lowIdx = highIdx = this.nalFreqs.length - 1;
                }
            }

            if (lowIdx === highIdx) {
                eqGains.push(nalGains[lowIdx]);
            } else {
                const ratio = (eqFreq - this.nalFreqs[lowIdx]) / (this.nalFreqs[highIdx] - this.nalFreqs[lowIdx]);
                eqGains.push(nalGains[lowIdx] + ratio * (nalGains[highIdx] - nalGains[lowIdx]));
            }
        }
        return eqGains.map(g => Math.round(g * 10) / 10);
    }

    /**
     * Calcula parámetros WDRC basados en severidad
     */
    _computeWdrcParams(audiogram, eqGains) {
        const avgHL = audiogram.thresholds.reduce((a, b) => a + b, 0) / audiogram.thresholds.length;
        const maxGain = Math.max(...eqGains);

        let compressionKnee, compressionRatio, attackMs, releaseMs;

        if (avgHL <= 30) {
            // Pérdida leve
            compressionKnee = 55;
            compressionRatio = 1.5;
            attackMs = 5;
            releaseMs = 100;
        } else if (avgHL <= 50) {
            // Pérdida moderada
            compressionKnee = 50;
            compressionRatio = 2.0;
            attackMs = 5;
            releaseMs = 100;
        } else if (avgHL <= 70) {
            // Pérdida severa
            compressionKnee = 45;
            compressionRatio = 2.5;
            attackMs = 5;
            releaseMs = 150;
        } else {
            // Pérdida profunda
            compressionKnee = 40;
            compressionRatio = 3.0;
            attackMs = 5;
            releaseMs = 200;
        }

        return {
            expansionKnee: 35,
            expansionRatio: 2.0,
            compressionKnee: compressionKnee,
            compressionRatio: Math.min(compressionRatio, this.safety.maxCompressionRatio),
            attackMs: attackMs,
            releaseMs: releaseMs,
            makeupGain: 0 // La ganancia viene del EQ, no del WDRC
        };
    }

    /**
     * Calcula MPO seguro para el paciente
     */
    _computeMPO(audiogram, isChild) {
        // Estimar UCL (Uncomfortable Loudness Level)
        const avgHL = audiogram.thresholds.reduce((a, b) => a + b, 0) / audiogram.thresholds.length;
        const estimatedUCL = 100 + 0.15 * avgHL;

        // Safety margin más conservador para niños
        const safetyMargin = isChild ? 10 : 5;
        const mpoThreshold = Math.min(estimatedUCL - safetyMargin, this.safety.maxMPO_dBSPL);

        return {
            threshold_dBSPL: Math.round(mpoThreshold),
            attackMs: 0.5,
            releaseMs: 10,
            kneeType: 'hard' // Peak limiter
        };
    }

    /**
     * Configura reducción de ruido según pérdida
     */
    _computeNR(audiogram) {
        const avgHL = audiogram.thresholds.reduce((a, b) => a + b, 0) / audiogram.thresholds.length;

        // Más NR para pérdidas leves (donde el ruido es más molesto)
        // Menos NR para pérdidas severas (donde la audibilidad es prioridad)
        let aggressiveness;
        if (avgHL <= 30) aggressiveness = 0.7;
        else if (avgHL <= 50) aggressiveness = 0.5;
        else if (avgHL <= 70) aggressiveness = 0.3;
        else aggressiveness = 0.2;

        return {
            enabled: true,
            aggressiveness: aggressiveness,
            gainFloor: 0.18, // -15 dB mínimo (preservar consonantes)
            subbands: 8
        };
    }

    /**
     * Obtiene RECD por edad
     */
    _getRECD(age) {
        const groups = config.clinical.ageGroups;
        let group;
        if (age < 1) group = groups[0];
        else if (age < 2) group = groups[1];
        else if (age < 5) group = groups[2];
        else group = groups[3];

        return {
            ageGroup: group.label,
            offsets: group.recdOffset
        };
    }

    /**
     * Valida que la configuración sea segura
     */
    _validateSafety(dspConfig) {
        const issues = [];
        const warnings = [];

        // Verificar ganancia máxima por banda
        for (let i = 0; i < dspConfig.eq.gains.length; i++) {
            if (dspConfig.eq.gains[i] > this.safety.maxGainPerBand_dB) {
                issues.push(`Banda ${i + 1} (${this.eqFreqs[i]}Hz): ganancia ${dspConfig.eq.gains[i]}dB excede máximo ${this.safety.maxGainPerBand_dB}dB`);
            }
        }

        // Verificar MPO
        if (dspConfig.mpo.threshold_dBSPL > this.safety.maxMPO_dBSPL) {
            issues.push(`MPO ${dspConfig.mpo.threshold_dBSPL} dB SPL excede máximo seguro ${this.safety.maxMPO_dBSPL} dB SPL`);
        }

        // Verificar compression ratio
        if (dspConfig.wdrc.compressionRatio > this.safety.maxCompressionRatio) {
            warnings.push(`CR ${dspConfig.wdrc.compressionRatio}:1 es alto — puede reducir inteligibilidad`);
        }

        // Verificar ganancia total estimada
        const maxEqGain = Math.max(...dspConfig.eq.gains);
        const totalGain = maxEqGain + dspConfig.volume.masterGain;
        if (totalGain > this.safety.maxTotalGain_dB) {
            warnings.push(`Ganancia total estimada ${totalGain}dB — el WDRC y MPO protegerán`);
        }

        return {
            safe: issues.length === 0,
            issues: issues,
            warnings: warnings
        };
    }

    /**
     * Genera explicación local (sin AI)
     */
    _generateLocalExplanation(audiogram, dspConfig, patient) {
        const avgHL = audiogram.thresholds.reduce((a, b) => a + b, 0) / audiogram.thresholds.length;
        const maxGain = Math.max(...dspConfig.eq.gains);
        const severity = avgHL <= 25 ? 'leve' : avgHL <= 50 ? 'moderada' : avgHL <= 70 ? 'severa' : 'profunda';

        return {
            summary: `Prescripción NAL-NL2 para pérdida ${severity} (promedio ${Math.round(avgHL)} dB HL). ` +
                `Ganancia máxima: ${maxGain} dB en frecuencias altas. ` +
                `MPO: ${dspConfig.mpo.threshold_dBSPL} dB SPL. ` +
                `Compresión: ${dspConfig.wdrc.compressionRatio}:1 sobre ${dspConfig.wdrc.compressionKnee} dB SPL.`,
            details: [
                `Pérdida auditiva: ${severity} (PTA = ${Math.round(avgHL)} dB HL)`,
                `Prescripción: NAL-NL2 ${patient.isChild ? 'con ajuste pediátrico (+4 dB)' : 'adulto'}`,
                `EQ: 12 bandas, ganancia máxima ${maxGain} dB`,
                `WDRC: Expansión bajo ${dspConfig.wdrc.expansionKnee} dB SPL, compresión sobre ${dspConfig.wdrc.compressionKnee} dB SPL`,
                `MPO: ${dspConfig.mpo.threshold_dBSPL} dB SPL (seguridad pediátrica)`,
                `NR: ${dspConfig.nr.enabled ? `activo, agresividad ${dspConfig.nr.aggressiveness}` : 'desactivado'}`,
                `AFC: ${dspConfig.afc.enabled ? 'activo (NLMS 64 taps)' : 'desactivado'}`
            ]
        };
    }

    /**
     * Genera explicación con OpenAI
     */
    async _generateAIExplanation(audiogram, dspConfig, patient) {
        const prompt = `Eres un audiólogo experto. Explica en español, de forma clara y profesional, 
la siguiente prescripción de audífono digital para un paciente ${patient.isChild ? 'pediátrico' : 'adulto'} 
de ${patient.age} años.

Audiograma (dB HL por frecuencia):
${audiogram.frequencies.map((f, i) => `${f}Hz: ${audiogram.thresholds[i]} dB HL`).join(', ')}

Configuración prescrita:
- EQ gains: ${dspConfig.eq.gains.map((g, i) => `${this.eqFreqs[i]}Hz=${g}dB`).join(', ')}
- WDRC: Expansión <${dspConfig.wdrc.expansionKnee}dB, Compresión >${dspConfig.wdrc.compressionKnee}dB (${dspConfig.wdrc.compressionRatio}:1)
- MPO: ${dspConfig.mpo.threshold_dBSPL} dB SPL
- NR: agresividad ${dspConfig.nr.aggressiveness}

Explica:
1. Por qué se eligieron estos valores
2. Qué beneficio tendrá el paciente
3. Qué precauciones tener

Responde en máximo 200 palabras.`;

        const response = await this.openai.chat.completions.create({
            model: config.openai.model,
            messages: [{ role: 'user', content: prompt }],
            temperature: config.openai.temperature,
            max_tokens: 500
        });

        return {
            summary: response.choices[0].message.content,
            details: [],
            aiGenerated: true
        };
    }
}

module.exports = { FittingAssistant };
