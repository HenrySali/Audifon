/**
 * RAG (Retrieval-Augmented Generation) para Desarrollo
 * 
 * Indexa toda la documentación y código del proyecto para permitir
 * búsquedas semánticas y respuestas contextuales sobre la implementación.
 * 
 * Uso:
 *   const { DevRAG } = require('./rag');
 *   const rag = new DevRAG(openaiClient);
 *   const answer = await rag.query("¿Cómo funciona el crossfade entre presets?");
 */

const fs = require('fs');
const path = require('path');
const config = require('../config');

class DevRAG {
    constructor(openaiClient = null) {
        this.openai = openaiClient;
        this.documents = [];
        this.codeIndex = [];
        this._loadDocuments();
    }

    /**
     * Carga documentos y código indexado
     */
    _loadDocuments() {
        // Cargar knowledge base
        const contentPath = path.join(config.paths.knowledgeBase, 'knowledge-content.json');
        if (fs.existsSync(contentPath)) {
            this.documents = JSON.parse(fs.readFileSync(contentPath, 'utf-8'));
        }

        // Indexar código fuente del web-simulator
        this._indexCodeFiles(path.join(config.paths.webSimulator, 'src'), 'web-simulator/src');

        // Indexar firmware headers
        this._indexCodeFiles(path.join(config.paths.firmware, 'src'), 'firmware/src', ['.h', '.c']);
    }

    /**
     * Indexa archivos de código
     */
    _indexCodeFiles(dir, prefix, extensions = ['.js', '.ts']) {
        if (!fs.existsSync(dir)) return;

        const items = fs.readdirSync(dir, { withFileTypes: true });
        for (const item of items) {
            const fullPath = path.join(dir, item.name);
            if (item.isDirectory() && !item.name.startsWith('.')) {
                this._indexCodeFiles(fullPath, `${prefix}/${item.name}`, extensions);
            } else if (item.isFile() && extensions.some(ext => item.name.endsWith(ext))) {
                try {
                    const content = fs.readFileSync(fullPath, 'utf-8');
                    this.codeIndex.push({
                        path: `${prefix}/${item.name}`,
                        type: 'code',
                        language: item.name.endsWith('.js') ? 'javascript' : 
                                  item.name.endsWith('.c') ? 'c' : 
                                  item.name.endsWith('.h') ? 'c-header' : 'unknown',
                        functions: this._extractFunctions(content),
                        content: content.substring(0, 4000)
                    });
                } catch (err) { /* skip unreadable */ }
            }
        }
    }

    /**
     * Extrae nombres de funciones/clases de un archivo
     */
    _extractFunctions(content) {
        const functions = [];

        // JavaScript: function name(), const name = (), class Name
        const jsPatterns = [
            /(?:function|async function)\s+(\w+)/g,
            /(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?\(/g,
            /class\s+(\w+)/g,
            /(\w+)\s*\([^)]*\)\s*\{/g
        ];

        // C: tipo nombre(params)
        const cPatterns = [
            /(?:void|int|float|bool|static)\s+(\w+)\s*\(/g
        ];

        const patterns = [...jsPatterns, ...cPatterns];
        for (const pattern of patterns) {
            let match;
            while ((match = pattern.exec(content)) !== null) {
                if (!functions.includes(match[1]) && match[1].length > 2) {
                    functions.push(match[1]);
                }
            }
        }

        return functions.slice(0, 30); // Limitar
    }

    /**
     * Busca en documentación y código
     * @param {string} query - Pregunta del desarrollador
     * @returns {Object} Respuesta con contexto y fuentes
     */
    async query(query) {
        // 1. Buscar en documentación
        const docResults = this._searchDocuments(query);

        // 2. Buscar en código
        const codeResults = this._searchCode(query);

        // 3. Si no hay AI, devolver resultados raw
        if (!this.openai) {
            return {
                answer: null,
                documents: docResults,
                code: codeResults,
                suggestion: 'Configura OPENAI_API_KEY para obtener respuestas generadas por AI'
            };
        }

        // 4. Generar respuesta con AI
        const context = this._buildContext(docResults, codeResults);
        const response = await this.openai.chat.completions.create({
            model: config.openai.modelAdvanced,
            messages: [
                {
                    role: 'system',
                    content: `Eres un desarrollador senior del proyecto PSK Hearing Aid.
Respondes preguntas técnicas sobre la implementación usando el contexto proporcionado.
Incluye snippets de código cuando sea relevante. Responde en español.
Si la respuesta requiere ver más código del que tienes, indícalo.

CONTEXTO DEL PROYECTO:
${context}`
                },
                { role: 'user', content: query }
            ],
            temperature: 0.2,
            max_tokens: 2000
        });

        return {
            answer: response.choices[0].message.content,
            documents: docResults.map(d => ({ path: d.path, title: d.title })),
            code: codeResults.map(c => ({ path: c.path, functions: c.matchedFunctions })),
            tokensUsed: response.usage?.total_tokens || 0
        };
    }

    /**
     * Busca documentos relevantes
     */
    _searchDocuments(query) {
        const queryLower = query.toLowerCase();
        const words = queryLower.split(/\s+/).filter(w => w.length > 3);

        return this.documents
            .map(doc => {
                let score = 0;
                const content = (doc.content || '').toLowerCase();
                const title = (doc.title || '').toLowerCase();

                for (const word of words) {
                    if (title.includes(word)) score += 10;
                    score += (content.match(new RegExp(word, 'g')) || []).length;
                }
                return { ...doc, score };
            })
            .filter(d => d.score > 2)
            .sort((a, b) => b.score - a.score)
            .slice(0, 3);
    }

    /**
     * Busca en el índice de código
     */
    _searchCode(query) {
        const queryLower = query.toLowerCase();
        const words = queryLower.split(/\s+/).filter(w => w.length > 2);

        return this.codeIndex
            .map(file => {
                let score = 0;
                const matchedFunctions = [];

                // Match en path
                for (const word of words) {
                    if (file.path.toLowerCase().includes(word)) score += 5;
                }

                // Match en funciones
                for (const func of file.functions) {
                    const funcLower = func.toLowerCase();
                    for (const word of words) {
                        if (funcLower.includes(word)) {
                            score += 3;
                            if (!matchedFunctions.includes(func)) {
                                matchedFunctions.push(func);
                            }
                        }
                    }
                }

                // Match en contenido
                const content = (file.content || '').toLowerCase();
                for (const word of words) {
                    score += Math.min((content.match(new RegExp(word, 'g')) || []).length, 3);
                }

                return { ...file, score, matchedFunctions };
            })
            .filter(f => f.score > 3)
            .sort((a, b) => b.score - a.score)
            .slice(0, 3);
    }

    /**
     * Construye contexto para el LLM
     */
    _buildContext(docResults, codeResults) {
        let context = '';

        if (docResults.length > 0) {
            context += '=== DOCUMENTACIÓN ===\n';
            for (const doc of docResults) {
                context += `\n[${doc.title}] (${doc.path}):\n`;
                context += (doc.content || '').substring(0, 1500) + '\n';
            }
        }

        if (codeResults.length > 0) {
            context += '\n=== CÓDIGO FUENTE ===\n';
            for (const code of codeResults) {
                context += `\n[${code.path}] Funciones: ${code.matchedFunctions.join(', ')}\n`;
                context += (code.content || '').substring(0, 2000) + '\n';
            }
        }

        return context.substring(0, 8000); // Limitar contexto total
    }
}

module.exports = { DevRAG };
