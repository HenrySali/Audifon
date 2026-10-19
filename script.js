// Array para almacenar los equipos
let equipos = [];

// Cargar equipos del localStorage al iniciar
document.addEventListener('DOMContentLoaded', () => {
    cargarEquipos();
    actualizarTabla();
});

// Manejar el envío del formulario
document.getElementById('equipoForm').addEventListener('submit', (e) => {
    e.preventDefault();
    agregarEquipo();
});

// Botón de exportar
document.getElementById('exportarBtn').addEventListener('click', exportarExcel);

/**
 * Agregar un nuevo equipo
 */
function agregarEquipo() {
    const numeroSerie = document.getElementById('numeroSerie').value.trim();
    const claseEquipo = document.getElementById('claseEquipo').value.trim();
    const certificado = document.getElementById('certificado').value;

    // Validación
    if (!numeroSerie || !claseEquipo || !certificado) {
        alert('Por favor completa todos los campos');
        return;
    }

    // Crear objeto de equipo
    const equipo = {
        id: Date.now(),
        numeroSerie,
        claseEquipo,
        certificado,
        fecha: new Date().toLocaleDateString('es-ES')
    };

    // Agregar al array
    equipos.push(equipo);

    // Guardar en localStorage
    guardarEquipos();

    // Limpiar formulario
    document.getElementById('equipoForm').reset();

    // Actualizar tabla
    actualizarTabla();

    // Feedback visual
    mostrarMensajeExito('Equipo agregado correctamente');
}

/**
 * Actualizar la tabla con los equipos
 */
function actualizarTabla() {
    const container = document.getElementById('tablaContainer');

    if (equipos.length === 0) {
        container.innerHTML = '<p class="sin-datos">No hay equipos cargados aún</p>';
        return;
    }

    let html = `
        <table>
            <thead>
                <tr>
                    <th>Número de Serie</th>
                    <th>Clase de Equipo</th>
                    <th>Certificado</th>
                    <th>Fecha de Ingreso</th>
                    <th>Acciones</th>
                </tr>
            </thead>
            <tbody>
    `;

    equipos.forEach((equipo, index) => {
        const claseCertificado = equipo.certificado === 'Sí' ? 'certificado-si' : 'certificado-no';
        html += `
            <tr>
                <td>${escaparHTML(equipo.numeroSerie)}</td>
                <td>${escaparHTML(equipo.claseEquipo)}</td>
                <td><span class="${claseCertificado}">${equipo.certificado}</span></td>
                <td>${equipo.fecha}</td>
                <td class="acciones">
                    <button class="btn-eliminar" onclick="eliminarEquipo(${equipo.id})">🗑️ Eliminar</button>
                </td>
            </tr>
        `;
    });

    html += `
            </tbody>
        </table>
    `;

    container.innerHTML = html;
}

/**
 * Eliminar un equipo por ID
 */
function eliminarEquipo(id) {
    if (confirm('¿Estás seguro de que deseas eliminar este equipo?')) {
        equipos = equipos.filter(eq => eq.id !== id);
        guardarEquipos();
        actualizarTabla();
        mostrarMensajeExito('Equipo eliminado correctamente');
    }
}

/**
 * Guardar equipos en localStorage
 */
function guardarEquipos() {
    localStorage.setItem('equipos', JSON.stringify(equipos));
}

/**
 * Cargar equipos del localStorage
 */
function cargarEquipos() {
    const datos = localStorage.getItem('equipos');
    if (datos) {
        equipos = JSON.parse(datos);
    }
}

/**
 * Exportar a Excel
 */
function exportarExcel() {
    if (equipos.length === 0) {
        alert('No hay equipos para exportar');
        return;
    }

    // Crear contenido CSV
    let csv = 'Número de Serie,Clase de Equipo,Certificado,Fecha de Ingreso\n';

    equipos.forEach(equipo => {
        csv += `"${equipo.numeroSerie}","${equipo.claseEquipo}","${equipo.certificado}","${equipo.fecha}"\n`;
    });

    // Convertir CSV a datos de Excel (usando HTML)
    const hojaExcel = generarHojaExcel(equipos);

    // Crear blob y descargar
    const blob = new Blob([hojaExcel], { type: 'application/vnd.ms-excel;charset=utf-8;' });
    const link = document.createElement('a');
    const url = URL.createObjectURL(blob);
    
    link.setAttribute('href', url);
    link.setAttribute('download', `Equipos_Relevados_${new Date().toLocaleDateString('es-ES').replace(/\//g, '-')}.xls`);
    link.style.visibility = 'hidden';
    
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);

    mostrarMensajeExito('Archivo Excel exportado correctamente');
}

/**
 * Generar tabla HTML para Excel
 */
function generarHojaExcel(datos) {
    const fecha = new Date().toLocaleDateString('es-ES');
    let html = `
        <html xmlns:x="urn:schemas-microsoft-com:office:excel">
        <head>
            <meta charset="UTF-8">
            <style>
                table {
                    border-collapse: collapse;
                    width: 100%;
                }
                th {
                    background-color: #2c3e50;
                    color: white;
                    padding: 10px;
                    border: 1px solid #000;
                    text-align: left;
                    font-weight: bold;
                }
                td {
                    padding: 10px;
                    border: 1px solid #000;
                }
                tr:nth-child(even) {
                    background-color: #f9f9f9;
                }
            </style>
        </head>
        <body>
            <h2>Relevamiento de Equipos</h2>
            <p>Fecha de Exportación: ${fecha}</p>
            <table border="1">
                <thead>
                    <tr>
                        <th>Número de Serie</th>
                        <th>Clase de Equipo</th>
                        <th>Certificado</th>
                        <th>Fecha de Ingreso</th>
                    </tr>
                </thead>
                <tbody>
    `;

    datos.forEach(equipo => {
        html += `
            <tr>
                <td>${escaparHTML(equipo.numeroSerie)}</td>
                <td>${escaparHTML(equipo.claseEquipo)}</td>
                <td>${equipo.certificado}</td>
                <td>${equipo.fecha}</td>
            </tr>
        `;
    });

    html += `
                </tbody>
            </table>
        </body>
        </html>
    `;

    return html;
}

/**
 * Mostrar mensaje de éxito temporal
 */
function mostrarMensajeExito(mensaje) {
    const alerta = document.createElement('div');
    alerta.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        background: #27ae60;
        color: white;
        padding: 15px 20px;
        border-radius: 8px;
        box-shadow: 0 4px 12px rgba(39, 174, 96, 0.3);
        z-index: 1000;
        animation: slideIn 0.3s ease;
    `;
    alerta.textContent = mensaje;

    document.body.appendChild(alerta);

    setTimeout(() => {
        alerta.style.animation = 'slideOut 0.3s ease';
        setTimeout(() => alerta.remove(), 300);
    }, 2000);
}

/**
 * Escapar caracteres HTML para evitar inyección
 */
function escaparHTML(texto) {
    const div = document.createElement('div');
    div.textContent = texto;
    return div.innerHTML;
}

// Agregar estilos de animación
const style = document.createElement('style');
style.textContent = `
    @keyframes slideIn {
        from {
            transform: translateX(400px);
            opacity: 0;
        }
        to {
            transform: translateX(0);
            opacity: 1;
        }
    }

    @keyframes slideOut {
        from {
            transform: translateX(0);
            opacity: 1;
        }
        to {
            transform: translateX(400px);
            opacity: 0;
        }
    }
`;
document.head.appendChild(style);
