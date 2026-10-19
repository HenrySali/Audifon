/**
 * Funciones para interactuar con GitHub API
 */

/**
 * Cargar equipos desde el archivo JSON en GitHub
 */
async function cargarEquiposGitHub() {
    const token = obtenerToken();
    
    if (!token) {
        console.log('No hay token de GitHub, usando datos locales');
        cargarEquiposLocal();
        return;
    }

    try {
        const url = obtenerUrlAPI();
        const response = await fetch(url, {
            headers: {
                'Authorization': `token ${token}`,
                'Accept': 'application/vnd.github.v3.raw'
            }
        });

        if (response.status === 404) {
            console.log('Archivo no encontrado, creando nuevo...');
            equipos = [];
            guardarEquiposGitHub();
            return;
        }

        if (!response.ok) {
            throw new Error(`Error: ${response.status} ${response.statusText}`);
        }

        const contenido = await response.text();
        equipos = JSON.parse(contenido || '[]');
        console.log('Equipos cargados desde GitHub:', equipos);
        actualizarTabla();
        mostrarMensajeExito('Datos sincronizados desde GitHub');
    } catch (error) {
        console.error('Error al cargar desde GitHub:', error);
        mostrarMensajeError('Error al sincronizar desde GitHub. Usando datos locales.');
        cargarEquiposLocal();
    }
}

/**
 * Guardar equipos en GitHub
 */
async function guardarEquiposGitHub() {
    const token = obtenerToken();
    
    if (!token) {
        console.log('No hay token, guardando solo localmente');
        guardarEquiposLocal();
        return;
    }

    try {
        // Primero obtener el SHA del archivo actual
        const url = obtenerUrlAPI();
        let sha = null;

        try {
            const response = await fetch(url, {
                headers: {
                    'Authorization': `token ${token}`,
                    'Accept': 'application/vnd.github.v3+json'
                }
            });

            if (response.ok) {
                const data = await response.json();
                sha = data.sha;
            }
        } catch (e) {
            // El archivo puede no existir aún
        }

        // Preparar contenido
        const contenido = btoa(JSON.stringify(equipos, null, 2)); // Base64 encoding
        
        const body = {
            message: `Actualizar equipos - ${new Date().toLocaleString('es-ES')}`,
            content: contenido,
            branch: GITHUB_CONFIG.branch
        };

        if (sha) {
            body.sha = sha;
        }

        const response = await fetch(url, {
            method: 'PUT',
            headers: {
                'Authorization': `token ${token}`,
                'Accept': 'application/vnd.github.v3+json',
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(body)
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.message || `Error: ${response.status}`);
        }

        console.log('Equipos guardados en GitHub exitosamente');
        mostrarMensajeExito('✅ Datos sincronizados con GitHub');
    } catch (error) {
        console.error('Error al guardar en GitHub:', error);
        mostrarMensajeError(`Error al guardar: ${error.message}`);
    }
}

/**
 * Verificar conexión con GitHub
 */
async function verificarConexionGitHub(token) {
    try {
        const response = await fetch('https://api.github.com/user', {
            headers: {
                'Authorization': `token ${token}`,
                'Accept': 'application/vnd.github.v3+json'
            }
        });

        if (response.ok) {
            const data = await response.json();
            return { valido: true, usuario: data.login };
        } else {
            return { valido: false, error: 'Token inválido' };
        }
    } catch (error) {
        return { valido: false, error: error.message };
    }
}
