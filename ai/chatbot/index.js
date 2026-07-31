/**
 * Chatbot Técnico para Audiólogos
 * 
 * Responde preguntas sobre el sistema de audífono digital usando
 * la documentación del proyecto como knowledge base (RAG local).
 * 
 * Uso:
 *   const { HearingAidChatbot } = require('./chatbot');
 *   const bot = new HearingAidChatbot(openaiClient);
 *   const answer = await bot.ask("¿Por qué el MPO está en 110 dB SPL?");
 */

const fs = require('fs');
const path = require('path');
const config = require('../config');

class HearingAidChatbot {
    constructor(openaiClient) {
        this.openai = openaiClient;
        this.knowledgeBase = null;
        this.conversationHistory = [];
        this.maxHistoryLength = 10;
        this._loadKnowledgeBase();
    }

    /**
     * Carga el knowledge base indexado
     */
    _loadKnowledgeBase() {
        const contentPath = path.join(config.paths.knowledgeBase, 'knowledge-content.json');
        const indexPath = path.join(config.paths.knowledgeBase, 'knowledge-index.json');

        try {
            if (fs.existsSync(contentPath)) {
                this.knowledgeBase = JSON.parse(fs.readFileSync(contentPath, 'utf-8'));
            }
            if (fs.existsSync(indexPath)) {
                this.index = JSON.parse(fs.readFileSync(indexPath, 'utf-8'));
            }
        } catch (err) {
            console.warn('⚠ Knowledge base no encontrada. Ejecutar: npm run build-kb');
            this.knowledgeBase = [];
            this.index = { documents: [] };
        }
    }

    /**
     * Responde una pregunta usando RAG
     * @param {string} question - Pregunta del usuario
     * @param {Object} context - Contexto adicional (paciente actual, config activa, etc.)
     * @returns {Object} Respuesta con fuentes
     */
    async ask(question, context = {}) {
        // 1. Buscar documentos relevantes
        const relevantDocs = this._searchRelevant(question);

        // 2. Construir contexto para el LLM
        const systemPrompt = this._buildSystemPrompt(relevantDocs, context);

        // 3. Agregar a historial
        this.conversationHistory.push({ role: 'user', content: question });
        if (this.conversationHistory.length > this.maxHistoryLength * 2) {
            this.conversationHistory = this.conversationHistory.slice(-this.maxHistoryLength * 2);
        }

        // 4. Llamar al LLM
        const messages = [
            { role: 'system', content: systemPrompt },
            ...this.conversationHistory
        ];

        const response = await this.openai.chat.completions.create({
            model: config.openai.model,
            messages: messages,
            temperature: config.openai.temperature,
            max_tokens: config.openai.maxTokens
        });

        const answer = response.choices[0].message.content;

        // 5. Agregar respuesta al historial
        this.conversationHistory.push({ role: 'assistant', content: answer });

        return {
            answer: answer,
            sources: relevantDocs.map(d => ({ path: d.path, title: d.title })),
            tokensUsed: response.usage?.total_tokens || 0
        };
    }

    /**
     * Busca documentos relevantes por keywords
     */
    _searchRelevant(question, maxResults = 4) {
        if (!this.knowledgeBase || this.knowledgeBase.length === 0) return [];

        const questionLower = question.toLowerCase();
        const questionWords = questionLower.split(/\s+/).filter(w => w.length > 3);

        // Score cada documento por relevancia
        const scored = this.knowledgeBase.map(doc => {
            let score = 0;
            const contentLower = (doc.content || '').toLowerCase();
            const titleLower = (doc.title || '').toLowerCase();

            // Match en título (peso alto)
            for (const word of questionWords) {
                if (titleLower.includes(word)) score += 10;
            }

            // Match en contenido
            for (const word of questionWords) {
                const matches = (contentLower.match(new RegExp(word, 'g')) || []).length;
                score += Math.min(matches, 5); // Cap por palabra
            }

            // Bonus por keywords técnicos
            const technicalTerms = ['wdrc', 'mpo', 'nal', 'dsl', 'ansi', 'eq', 'biquad',
                'feedback', 'calibración', 'compresión', 'ganancia', 'audiograma',
                'prescripción', 'pipeline', 'firmware', 'flutter'];
            for (const term of technicalTerms) {
                if (questionLower.includes(term) && contentLower.includes(term)) {
                    score += 5;
                }
            }

            return { ...doc, score };
        });

        // Ordenar por score y devolver top N
        return scored
            .filter(d => d.score > 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, maxResults);
    }

    /**
     * Construye el system prompt con contexto RAG
     */
    _buildSystemPrompt(relevantDocs, context) {
        let prompt = `Eres un asistente técnico experto en audífonos digitales del proyecto PSK Hearing Aid.
Tu rol es responder preguntas de audiólogos y desarrolladores sobre el sistema.

REGLAS:
- Responde en español
- Sé preciso y técnico cuando corresponda
- Cita las fuentes cuando uses información de la documentación
- Si no sabes algo, dilo claramente
- Para preguntas clínicas, aclara que no reemplazas el criterio profesional

DOCUMENTACIÓN RELEVANTE:
`;

        for (const doc of relevantDocs) {
            prompt += `\n--- ${doc.title} (${doc.path}) ---\n`;
            prompt += (doc.content || '').substring(0, 1500) + '\n';
        }

        if (context.currentConfig) {
            prompt += `\nCONFIGURACIÓN ACTIVA DEL PACIENTE:\n`;
            prompt += JSON.stringify(context.currentConfig, null, 2).substring(0, 500);
        }

        if (context.patientInfo) {
            prompt += `\nINFO DEL PACIENTE: ${JSON.stringify(context.patientInfo)}`;
        }

        return prompt;
    }

    /**
     * Resetea el historial de conversación
     */
    resetConversation() {
        this.conversationHistory = [];
    }

    /**
     * Obtiene preguntas sugeridas basadas en el contexto
     */
    getSuggestedQuestions(context = {}) {
        const suggestions = [
            '¿Cómo funciona el WDRC de 3 regiones?',
            '¿Por qué el MPO está limitado a 110 dB SPL para niños?',
            '¿Qué diferencia hay entre NAL-NL2 y DSL v5.0?',
            '¿Cómo se calibra el micrófono MEMS?',
            '¿Qué hace el cancelador de feedback?',
            '¿Cuál es la latencia del pipeline DSP?',
            '¿Cómo interpreto el Índice de Degradación?',
            '¿Qué significa THD < 3%?'
        ];

        if (context.currentConfig) {
            suggestions.unshift('¿Es correcta la configuración actual para este paciente?');
            suggestions.unshift('¿Qué ajustes recomiendas para mejorar la inteligibilidad?');
        }

        return suggestions;
    }
}

module.exports = { HearingAidChatbot };
