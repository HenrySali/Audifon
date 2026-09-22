// Configuración de la ruleta
let temas = [];
let girando = false;
let rotacionActual = 0;

const canvas = document.getElementById('ruletaCanvas');
const ctx = canvas.getContext('2d');
const temaInput = document.getElementById('temaInput');
const agregarBtn = document.getElementById('agregarBtn');
const jugarBtn = document.getElementById('jugarBtn');
const limpiarBtn = document.getElementById('limpiarBtn');
const temasContainer = document.getElementById('temasContainer');
const resultado = document.getElementById('resultado');

// ========== TEMAS PREDETERMINADOS ==========
const temasPredeterminados = [
    'Matemáticas',
    'Historia',
    'Biología',
    'Literatura',
    'Geografía',
    'Física',
    'Química',
    'Arte',
    'Educación Física',
    'Música',
    'Informática',
    'Inglés',
    'Filosofía',
    'Economía',
    'Psicología',
    'Sociología',
    'Derecho',
    'Medicina',
    'Arquitectura',
    'Ingeniería'
];

// ========== CARGAR TEMAS DEL LOCALSTORAGE ==========
function cargarTemas() {
    const temasGuardados = localStorage.getItem('temas');
    if (temasGuardados) {
        temas = JSON.parse(temasGuardados);
    } else {
        // Si no hay temas guardados, usar los predeterminados
        temas = [...temasPredeterminados];
        guardarTemas();
    }
    actualizarUI();
}

// ========== GUARDAR TEMAS EN LOCALSTORAGE ==========
function guardarTemas() {
    localStorage.setItem('temas', JSON.stringify(temas));
}

// ========== AGREGAR TEMA ==========
function agregarTema() {
    const tema = temaInput.value.trim();
    
    if (tema === '') {
        alert('Por favor ingresa un tema válido');
        return;
    }
    
    if (temas.includes(tema)) {
        alert('Este tema ya existe');
        return;
    }
    
    temas.push(tema);
    guardarTemas();
    temaInput.value = '';
    actualizarUI();
    temaInput.focus();
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
        resultado.innerHTML = '<p>Presiona JUGAR para seleccionar un tema</p>';
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
        
        // Dibujar texto
        const anguloTexto = anguloInicio + anguloPorSegmento / 2;
        const xTexto = centerX + Math.cos(anguloTexto) * (radius * 0.6);
        const yTexto = centerY + Math.sin(anguloTexto) * (radius * 0.6);
        
        ctx.save();
        ctx.translate(xTexto, yTexto);
        ctx.rotate(anguloTexto + Math.PI / 2);
        ctx.fillStyle = '#fff';
        ctx.font = 'bold 12px Arial';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        
        // Truncar texto si es muy largo
        let texto = temas[i];
        if (texto.length > 20) {
            texto = texto.substring(0, 17) + '...';
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
    
    // La aguja está en la parte superior (ángulo 0 o 2π)
    // Calculamos qué segmento está en esa posición
    const anguloAguja = 0;
    
    // Ajustamos por la rotación actual
    const anguloAjustado = (anguloAguja - rotacionActual) % (2 * Math.PI);
    const anguloNormalizado = anguloAjustado < 0 ? anguloAjustado + 2 * Math.PI : anguloAjustado;
    
    const indice = Math.floor(anguloNormalizado / anguloPorSegmento) % numSegmentos;
    
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

// Permitir agregar tema con Enter
temaInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') {
        agregarTema();
    }
});

// ========== INICIALIZAR ==========
cargarTemas();
