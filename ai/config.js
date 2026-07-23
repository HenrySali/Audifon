/**
 * Configuración central del módulo AI del audífono digital.
 * Todas las features AI comparten esta configuración.
 */

const path = require('path');

const config = {
    // OpenAI
    openai: {
        model: 'gpt-4o-mini',
        modelAdvanced: 'gpt-4o',
        temperature: 0.3,
        maxTokens: 2000,
        // API key se lee de variable de entorno
        apiKey: process.env.OPENAI_API_KEY || ''
    },

    // Paths del proyecto
    paths: {
        root: path.resolve(__dirname, '..'),
        docs: path.resolve(__dirname, '..', 'docs'),
        clinica: path.resolve(__dirname, '..', 'docs', 'clinica'),
        investigacion: path.resolve(__dirname, '..', 'docs', 'investigacion'),
        fabricantes: path.resolve(__dirname, '..', 'docs', 'fabricantes'),
        firmware: path.resolve(__dirname, '..', 'firmware'),
        webSimulator: path.resolve(__dirname, '..', 'web-simulator'),
        knowledgeBase: path.resolve(__dirname, 'knowledge-base')
    },

    // Parámetros clínicos de referencia
    clinical: {
        // Offset de calibración
        dbfsToSplOffset: {
            wav: 76,
            realtime: 120
        },
        // Límites de seguridad pediátricos
        safety: {
            maxMPO_dBSPL: 110,
            maxGainPerBand_dB: 30,
            maxTotalGain_dB: 40,
            minExpansionKnee_dBSPL: 30,
            maxCompressionRatio: 4.0
        },
        // Frecuencias del EQ de 12 bandas
        eqFrequencies: [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000],
        // Grupos etarios para RECD
        ageGroups: [
            { id: 'infant', label: '6-12 meses', recdOffset: [6, 5, 4, 4, 5, 7, 9, 11, 12, 14, 16, 18] },
            { id: 'toddler', label: '1-2 años', recdOffset: [4, 3, 3, 3, 4, 5, 7, 8, 9, 10, 12, 14] },
            { id: 'preschool', label: '2-5 años', recdOffset: [2, 2, 2, 2, 3, 4, 5, 6, 6, 7, 8, 10] },
            { id: 'child', label: '>5 años', recdOffset: [1, 1, 1, 1, 2, 2, 3, 3, 3, 4, 5, 6] }
        ]
    },

    // NAL-NL2 tabla simplificada (ganancia @ 65 dB SPL input)
    nalNL2: {
        // Filas: HL en pasos de 10 (20-80), Columnas: frecuencias [250,500,1k,2k,3k,4k,6k,8k]
        gainTable: {
            20: [0, 2, 3, 5, 5, 4, 3, 2],
            30: [2, 4, 6, 9, 9, 8, 6, 5],
            40: [4, 7, 10, 14, 14, 12, 10, 8],
            50: [6, 10, 14, 18, 18, 16, 14, 11],
            60: [8, 13, 18, 23, 22, 20, 17, 14],
            70: [10, 16, 22, 27, 26, 24, 20, 17],
            80: [12, 19, 25, 30, 29, 27, 23, 19]
        },
        // Frecuencias de la tabla NAL-NL2
        frequencies: [250, 500, 1000, 2000, 3000, 4000, 6000, 8000],
        // Ajuste pediátrico adicional (dB)
        pediatricBoost: 4
    }
};

module.exports = config;
