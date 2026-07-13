/**
 * Knowledge Base Builder
 * 
 * Lee toda la documentación del proyecto y genera un índice estructurado
 * que las features AI pueden consultar sin necesidad de embeddings externos.
 * 
 * Uso: node build-index.js
 * Salida: knowledge-index.json
 */

const fs = require('fs');
const path = require('path');
const config = require('../config');

/**
 * Recursivamente lee todos los .md de un directorio
 */
function readMarkdownFiles(dir, basePath = '') {
    const entries = [];
    if (!fs.existsSync(dir)) return entries;

    const items = fs.readdirSync(dir, { withFileTypes: true });
    for (const item of items) {
        const fullPath = path.join(dir, item.name);
        const relativePath = path.join(basePath, item.name);

        if (item.isDirectory() && !item.name.startsWith('.') && item.name !== 'node_modules') {
            entries.push(...readMarkdownFiles(fullPath, relativePath));
        } else if (item.isFile() && (item.name.endsWith('.md') || item.name.endsWith('.txt'))) {
            try {
                const content = fs.readFileSync(fullPath, 'utf-8');
                entries.push({
                    path: relativePath,
                    title: extractTitle(content, item.name),
                    category: categorize(relativePath),
                    summary: extractSummary(content),
                    keywords: extractKeywords(content),
                    charCount: content.length,
                    content: content.substring(0, 3000) // Primeros 3000 chars para contexto
                });
            } catch (err) {
                console.warn(`  ⚠ No se pudo leer: ${relativePath}`);
            }
        }
    }
    return entries;
}

/**
 * Extrae el título del documento (primer # heading)
 */
function extractTitle(content, filename) {
    const match = content.match(/^#\s+(.+)$/m);
    return match ? match[1].trim() : filename.replace(/\.(md|txt)$/, '');
}

/**
 * Categoriza el documento según su ruta
 */
function categorize(relativePath) {
    if (relativePath.includes('clinica')) return 'clinica';
    if (relativePath.includes('investigacion')) return 'investigacion';
    if (relativePath.includes('fabricantes')) return 'fabricantes';
    if (relativePath.includes('proyecto')) return 'proyecto';
    if (relativePath.includes('sesiones')) return 'sesiones';
    if (relativePath.includes('firmware')) return 'firmware';
    if (relativePath.includes('web-simulator')) return 'simulador';
    return 'general';
}

/**
 * Extrae un resumen (primeros 2-3 párrafos significativos)
 */
function extractSummary(content) {
    const lines = content.split('\n');
    const paragraphs = [];
    let current = '';

    for (const line of lines) {
        if (line.trim() === '') {
            if (current.trim().length > 50 && !current.startsWith('#') && !current.startsWith('|') && !current.startsWith('```')) {
                paragraphs.push(current.trim());
                if (paragraphs.length >= 2) break;
            }
            current = '';
        } else {
            current += ' ' + line;
        }
    }

    return paragraphs.join(' ').substring(0, 500);
}

/**
 * Extrae keywords del contenido
 */
function extractKeywords(content) {
    const technical = [
        'WDRC', 'MPO', 'EQ', 'NAL-NL2', 'DSL', 'ANSI', 'IEC', 'THD',
        'biquad', 'feedback', 'NR', 'AFC', 'audiograma', 'prescripción',
        'compresión', 'expansión', 'kneepoint', 'ganancia', 'calibración',
        'dBFS', 'dB SPL', 'frecuencia', 'pipeline', 'realtime', 'firmware',
        'BLE', 'Flutter', 'nRF5340', 'Zephyr', 'PCB', 'micrófono', 'MEMS',
        'Phonak', 'Starkey', 'Oticon', 'pediátrico', 'niños', 'audífono'
    ];

    const found = [];
    const contentLower = content.toLowerCase();
    for (const kw of technical) {
        if (contentLower.includes(kw.toLowerCase())) {
            found.push(kw);
        }
    }
    return found;
}

// --- Main ---
console.log('🔨 Building Knowledge Base Index...\n');

const allDocs = [];

// Leer docs/
console.log('📂 Leyendo docs/...');
const docsEntries = readMarkdownFiles(config.paths.docs, 'docs');
allDocs.push(...docsEntries);
console.log(`   → ${docsEntries.length} documentos`);

// Leer README principal
const readmePath = path.join(config.paths.root, 'README.md');
if (fs.existsSync(readmePath)) {
    const content = fs.readFileSync(readmePath, 'utf-8');
    allDocs.push({
        path: 'README.md',
        title: extractTitle(content, 'README.md'),
        category: 'general',
        summary: extractSummary(content),
        keywords: extractKeywords(content),
        charCount: content.length,
        content: content.substring(0, 3000)
    });
    console.log('   → README.md incluido');
}

// Leer firmware README
const fwReadme = path.join(config.paths.firmware, 'README.md');
if (fs.existsSync(fwReadme)) {
    const content = fs.readFileSync(fwReadme, 'utf-8');
    allDocs.push({
        path: 'firmware/README.md',
        title: extractTitle(content, 'firmware-README.md'),
        category: 'firmware',
        summary: extractSummary(content),
        keywords: extractKeywords(content),
        charCount: content.length,
        content: content.substring(0, 3000)
    });
}

// Generar índice
const index = {
    version: '1.0.0',
    generatedAt: new Date().toISOString(),
    totalDocuments: allDocs.length,
    categories: {},
    documents: allDocs.map(d => ({
        path: d.path,
        title: d.title,
        category: d.category,
        keywords: d.keywords,
        charCount: d.charCount,
        summary: d.summary
    }))
};

// Agrupar por categoría
for (const doc of allDocs) {
    if (!index.categories[doc.category]) {
        index.categories[doc.category] = { count: 0, docs: [] };
    }
    index.categories[doc.category].count++;
    index.categories[doc.category].docs.push(doc.path);
}

// Guardar índice
const outputPath = path.join(__dirname, 'knowledge-index.json');
fs.writeFileSync(outputPath, JSON.stringify(index, null, 2), 'utf-8');
console.log(`\n✅ Índice generado: ${outputPath}`);
console.log(`   Total: ${index.totalDocuments} documentos`);
console.log(`   Categorías: ${Object.keys(index.categories).join(', ')}`);

// Guardar contenido completo para RAG
const fullContent = allDocs.map(d => ({
    path: d.path,
    title: d.title,
    category: d.category,
    content: d.content
}));
const contentPath = path.join(__dirname, 'knowledge-content.json');
fs.writeFileSync(contentPath, JSON.stringify(fullContent, null, 2), 'utf-8');
console.log(`   Contenido RAG: ${contentPath}`);
