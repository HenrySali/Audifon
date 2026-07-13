/**
 * PSK Hearing Aid — AI Module
 * 
 * Módulo central de inteligencia artificial para el audífono digital.
 * Integra 6 features AI que usan la documentación clínica y técnica
 * del proyecto como knowledge base.
 * 
 * Features:
 * 1. Asistente de Fitting — Prescripción automática desde audiograma
 * 2. Auto-Diagnóstico — Interpreta calibración y explica problemas
 * 3. Chatbot Técnico — Responde preguntas de audiólogos
 * 4. Reportes Clínicos — Genera reportes profesionales de fitting
 * 5. RAG para Desarrollo — Búsqueda inteligente en código y docs
 * 6. Clasificador ML — Clasificación de entorno con aprendizaje
 * 
 * Uso rápido:
 *   const { createAISystem } = require('./ai');
 *   const ai = createAISystem({ apiKey: process.env.OPENAI_API_KEY });
 *   
 *   // Prescribir desde audiograma
 *   const fitting = await ai.fitting.prescribe(audiogram, patient);
 *   
 *   // Diagnosticar calibración
 *   const diagnosis = await ai.diagnostics.analyze(calibrationData);
 *   
 *   // Preguntar al chatbot
 *   const answer = await ai.chatbot.ask("¿Cómo funciona el WDRC?");
 *   
 *   // Generar reporte
 *   const report = await ai.reports.generate(sessionData);
 *   
 *   // Buscar en código/docs
 *   const result = await ai.rag.query("crossfade entre presets");
 *   
 *   // Clasificar entorno
 *   const env = ai.environment.predict(audioFeatures);
 */

const { FittingAssistant } = require('./fitting-assistant');
const { DiagnosticsEngine } = require('./diagnostics');
const { HearingAidChatbot } = require('./chatbot');
const { ReportGenerator } = require('./reports');
const { DevRAG } = require('./rag');
const { EnvironmentML } = require('./environment-ml');
const config = require('./config');

/**
 * Crea el sistema AI completo
 * @param {Object} options - { apiKey: string }
 * @returns {Object} Sistema AI con todas las features
 */
function createAISystem(options = {}) {
    const { apiKey } = options;
    let openaiClient = null;

    // Inicializar OpenAI si hay API key
    if (apiKey || config.openai.apiKey) {
        try {
            const OpenAI = require('openai');
            openaiClient = new OpenAI({ apiKey: apiKey || config.openai.apiKey });
        } catch (err) {
            console.warn('⚠ OpenAI no disponible. Features AI funcionarán en modo local.');
        }
    }

    return {
        fitting: new FittingAssistant(openaiClient),
        diagnostics: new DiagnosticsEngine(openaiClient),
        chatbot: openaiClient ? new HearingAidChatbot(openaiClient) : null,
        reports: new ReportGenerator(openaiClient),
        rag: new DevRAG(openaiClient),
        environment: new EnvironmentML(),
        config: config,

        // Utilidades
        isAIEnabled: () => openaiClient !== null,
        getStatus: () => ({
            openai: openaiClient !== null,
            model: config.openai.model,
            features: {
                fitting: true,
                diagnostics: true,
                chatbot: openaiClient !== null,
                reports: true,
                rag: true,
                environment: true
            }
        })
    };
}

module.exports = {
    createAISystem,
    FittingAssistant,
    DiagnosticsEngine,
    HearingAidChatbot,
    ReportGenerator,
    DevRAG,
    EnvironmentML,
    config
};
