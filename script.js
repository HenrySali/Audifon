// Configuración de la ruleta
let temas = [];
let girando = false;
let rotacionActual = 0;

// ========== ELEMENTOS DEL DOM ==========
const canvas = document.getElementById('ruletaCanvas');
const ctx = canvas.getContext('2d');
const temasInput = document.getElementById('temasInput');
const agregarBtn = document.getElementById('agregarBtn');
const jugarBtn = document.getElementById('jugarBtn');
const limpiarBtn = document.getElementById('limpiarBtn');
const temasContainer = document.getElementById('temasContainer');
const resultado = document.getElementById('resultado');

// ========== CARGAR TEMAS DEL LOCALSTORAGE ==========
function cargarTemas() {
    const temasGuardados = localStorage.getItem('temas');
    if (temasGuardados) {
        temas = JSON.parse(temasGuardados);
        actualizarUI();
    }
}

// ========== GUARDAR TEMAS EN LOCALSTORAGE ==========
function guardarTemas() {
    localStorage.setItem('temas', JSON.stringify(temas));
}

// ========== AGREGAR TEMAS ==========
function agregarTema() {
    const texto = temasInput.value.trim();
    
    if (texto === '') {
        alert('Por favor ingresa al menos un tema');
        return;
    }
    
    // Dividir por saltos de línea
    let nuevosTemas = [];
    const porLineas = texto.split('\n');
    
    porLineas.forEach(linea => {
        const temaLimpio = linea.trim();
        if (temaLimpio !== '') {
            nuevosTemas.push(temaLimpio);
        }
    });
    
    if (nuevosTemas.length === 0) {
        alert('No hay temas válidos para agregar');
        return;
    }
    
    let temasAgregados = 0;
    let temasDuplicados = 0;
    
    nuevosTemas.forEach(tema => {
        if (temas.includes(tema)) {
            temasDuplicados++;
        } else if (temas.length < 60) {
            temas.push(tema);
            temasAgregados++;
        }
    });
    
    if (temasAgregados > 0) {
        guardarTemas();
        temasInput.value = '';
        actualizarUI();
        
        let mensaje = `✅ Se agregaron ${temasAgregados} tema${temasAgregados > 1 ? 's' : ''}`;
        if (temasDuplicados > 0) {
            mensaje += `\n⚠️ ${temasDuplicados} ya existía${temasDuplicados > 1 ? 'n' : ''}`;
        }
        if (temas.length >= 60) {
            mensaje += `\n⚠️ Has alcanzado el máximo de 60 temas`;
        }
        alert(mensaje);
    } else {
        alert(`❌ Todos los temas ya existen o has alcanzado el máximo`);
    }
}

// ========== ELIMINAR TEMA ==========
function eliminarTema(indice) {
    temas.splice(indice, 1);
    guardarTemas();
    actualizarUI();
}

// ========== LIMPIAR TODO ==========
function limpiarTodo() {
    if (temas.length === 0) {
        alert('No hay temas para limpiar');
        return;
    }
    
    if (confirm('¿Estás seguro de que deseas eliminar todos los temas?')) {
        temas = [];
        guardarTemas();
        actualizarUI();
        resultado.className = 'resultado';
        resultado.innerHTML = '<p>Agrega temas y presiona JUGAR</p>';
    }
}

// ========== ACTUALIZAR INTERFAZ ==========
function actualizarUI() {
    // Actualizar lista de temas
    if (temas.length === 0) {
        temasContainer.innerHTML = '<p class="vacio">No hay temas aún. ¡Agrega uno!</p>';
        jugarBtn.disabled = true;
    } else {
        temasContainer.innerHTML = temas.map((tema, indice) => `
            <div class="tema-item">
                <span>${tema}</span>
                <button onclick="eliminarTema(${indice})">✕</button>
            </div>
        `).join('');
        jugarBtn.disabled = false;
    }
    
    // Actualizar contador
    document.getElementById('temaCount').textContent = temas.length;
    
    // Redibujar ruleta
    dibujarRuleta();
}

// ========== DIBUJAR RULETA ==========
function dibujarRuleta() {
    const centerX = canvas.width / 2;
    const centerY = canvas.height / 2;
    const radius = canvas.width / 2 - 10;
    
    // Limpiar canvas
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    
    if (temas.length === 0) {
        // Dibujar ruleta vacía
        ctx.beginPath();
        ctx.arc(centerX, centerY, radius, 0, 2 * Math.PI);
        ctx.fillStyle = '#ddd';
        ctx.fill();
        ctx.strokeStyle = '#999';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        ctx.fillStyle = '#666';
        ctx.font = 'bold 16px Arial';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText('Agrega temas para jugar', centerX, centerY);
        return;
    }
    
    const numSegmentos = temas.length;
    const anguloPorSegmento = (2 * Math.PI) / numSegmentos;
    const colores = generarColores(numSegmentos);
    
    // Ajustar tamaño de fuente según cantidad de temas
    let fontSize;
    if (numSegmentos <= 6) {
        fontSize = 14;
    } else if (numSegmentos <= 12) {
        fontSize = 11;
    } else if (numSegmentos <= 20) {
        fontSize = 9;
    } else {
        fontSize = 7;
    }
    
    // Dibujar segmentos
    for (let i = 0; i < numSegmentos; i++) {
        const anguloInicio = rotacionActual + i * anguloPorSegmento;
        const anguloFinal = anguloInicio + anguloPorSegmento;
        
        // Dibujar segmento
        ctx.beginPath();
        ctx.moveTo(centerX, centerY);
        ctx.arc(centerX, centerY, radius, anguloInicio, anguloFinal);
        ctx.closePath();
        ctx.fillStyle = colores[i];
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 2;
        ctx.stroke();
        
        // Dibujar texto en la punta (más espacio)
        const anguloTexto = anguloInicio + anguloPorSegmento / 2;
        // Mover el texto más hacia la punta del segmento (radius * 0.8 en lugar de 0.6)
        const distanciaRadio = numSegmentos > 15 ? 0.75 : 0.8;
        const xTexto = centerX + Math.cos(anguloTexto) * (radius * distanciaRadio);
        const yTexto = centerY + Math.sin(anguloTexto) * (radius * distanciaRadio);
        
        ctx.save();
        ctx.translate(xTexto, yTexto);
        ctx.rotate(anguloTexto + Math.PI / 2);
        ctx.fillStyle = '#fff';
        ctx.font = `bold ${fontSize}px Arial`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        
        // Truncar texto según cantidad de temas
        let texto = temas[i];
        let maxLength = numSegmentos > 12 ? 15 : 20;
        if (texto.length > maxLength) {
            texto = texto.substring(0, maxLength - 2) + '..';
        }
        ctx.fillText(texto, 0, 0);
        ctx.restore();
    }
    
    // Dibujar círculo central
    ctx.beginPath();
    ctx.arc(centerX, centerY, 15, 0, 2 * Math.PI);
    ctx.fillStyle = '#fff';
    ctx.fill();
    ctx.strokeStyle = '#667eea';
    ctx.lineWidth = 2;
    ctx.stroke();
}

// ========== GENERAR COLORES ==========
function generarColores(cantidad) {
    const coloresBase = [
        '#FF6B6B', '#4ECDC4', '#45B7D1', '#FFA07A', '#98D8C8',
        '#F7DC6F', '#BB8FCE', '#85C1E2', '#F8B88B', '#52C5A8',
        '#FF8A80', '#64B5F6', '#81C784', '#FFD54F', '#E57373'
    ];
    
    const colores = [];
    for (let i = 0; i < cantidad; i++) {
        colores.push(coloresBase[i % coloresBase.length]);
    }
    return colores;
}

// ========== JUGAR - GIRAR RULETA ==========
function jugar() {
    if (temas.length === 0 || girando) {
        return;
    }
    
    girando = true;
    jugarBtn.classList.add('girando');
    jugarBtn.disabled = true;
    resultado.className = 'resultado';
    resultado.innerHTML = '<p>¡Girando...</p>';
    
    // Número de vueltas + rotación final aleatoria
    const vueltasCompletas = 5;
    const rotacionAleatoria = Math.random() * (2 * Math.PI);
    const rotacionTotal = vueltasCompletas * (2 * Math.PI) + rotacionAleatoria;
    
    // Velocidad de animación en milisegundos
    const duracion = 3000;
    const inicio = Date.now();
    
    function animar() {
        const ahora = Date.now();
        const progreso = (ahora - inicio) / duracion;
        
        if (progreso < 1) {
            // Usar easing para que la rotación se desacelere
            const t = progreso;
            const easing = 1 - Math.pow(1 - t, 3); // Ease-out cubic
            rotacionActual = rotacionTotal * easing;
            dibujarRuleta();
            requestAnimationFrame(animar);
        } else {
            // Animación completa
            rotacionActual = rotacionTotal;
            rotacionActual = rotacionActual % (2 * Math.PI);
            dibujarRuleta();
            
            // Determinar tema ganador
            const temaGanador = determinarTemaGanador();
            mostrarResultado(temaGanador);
            
            girando = false;
            jugarBtn.classList.remove('girando');
            jugarBtn.disabled = false;
        }
    }
    
    animar();
}

// ========== DETERMINAR TEMA GANADOR ==========
function determinarTemaGanador() {
    const numSegmentos = temas.length;
    const anguloPorSegmento = (2 * Math.PI) / numSegmentos;
    
    // La aguja está en la parte superior
    // En Canvas: 0 = derecha, π/2 = abajo, π = izquierda, 3π/2 = arriba
    // Por eso usamos -π/2 o 3π/2 para la parte superior
    
    let anguloAguja = -Math.PI / 2; // Parte superior
    let indiceFlotante = (anguloAguja - rotacionActual) / anguloPorSegmento;
    
    // Normalizar indiceFlotante al rango [0, numSegmentos)
    indiceFlotante = indiceFlotante % numSegmentos;
    if (indiceFlotante < 0) {
        indiceFlotante += numSegmentos;
    }
    
    let indice = Math.floor(indiceFlotante);
    
    return temas[indice];
}

// ========== MOSTRAR RESULTADO ==========
function mostrarResultado(tema) {
    resultado.className = 'resultado ganador';
    resultado.innerHTML = `<p>🎉 ¡Tema Ganador! 🎉<br><strong>${tema}</strong></p>`;
}

// ========== EVENT LISTENERS ==========
agregarBtn.addEventListener('click', agregarTema);
jugarBtn.addEventListener('click', jugar);
limpiarBtn.addEventListener('click', limpiarTodo);

// Permitir agregar temas con Enter
temasInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') {
        agregarTema();
    }
});

// ========== INICIALIZAR ==========
cargarTemas();
