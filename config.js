// Configuración de GitHub API
const GITHUB_CONFIG = {
    owner: 'HenrySali',
    repo: 'Audifon',
    branch: 'main',
    dataPath: 'data/equipos.json',
    // Token debe ser proporcionado por el usuario en la interfaz
    token: null
};

// Obtener token del sessionStorage si está guardado
function obtenerToken() {
    return sessionStorage.getItem('githubToken') || GITHUB_CONFIG.token;
}

// Guardar token en sessionStorage
function guardarToken(token) {
    sessionStorage.setItem('githubToken', token);
    GITHUB_CONFIG.token = token;
}

// Limpiar token
function limpiarToken() {
    sessionStorage.removeItem('githubToken');
    GITHUB_CONFIG.token = null;
}

// Obtener URL base de GitHub API
function obtenerUrlAPI() {
    return `https://api.github.com/repos/${GITHUB_CONFIG.owner}/${GITHUB_CONFIG.repo}/contents/${GITHUB_CONFIG.dataPath}`;
}
