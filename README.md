# 📋 Sistema de Relevamiento de Equipos

Aplicación web colaborativa para registrar y gestionar equipos con sus certificados. Los datos se sincronizan en tiempo real a través de GitHub.

## Características

✅ **Ingreso de Equipos**
- Número de Serie
- Clase/Tipo de Equipo
- Estado del Certificado (Sí/No)
- Número de Piso (1, 2, 3)

✅ **Sincronización en GitHub**
- Todos los usuarios ven los mismos datos
- Sincronización automática desde cualquier dispositivo
- Datos persistentes en el repositorio

✅ **Gestión de Datos**
- Lista completa de equipos registrados
- Eliminar equipos
- Estado de conexión en tiempo real

✅ **Exportación**
- Exportar a archivo Excel (XLS)
- Incluye fecha de ingreso y exportación

## Cómo usar

### Primer uso
1. Abre la aplicación: https://henrysali.github.io/Audifon/
2. Haz clic en "🔑 Conectar GitHub"
3. Obtén un Personal Access Token desde GitHub:
   - Ve a [GitHub Settings → Tokens](https://github.com/settings/tokens)
   - Haz clic en "Generate new token"
   - Nombre: "Audifon"
   - Selecciona solo el permiso **repo**
   - Copia el token
4. Pega el token en la aplicación

### Usar la aplicación
1. Completa los campos del formulario
2. Haz clic en "Agregar Equipo"
3. Los datos se guardan automáticamente en GitHub
4. Otros usuarios verán los cambios al actualizar
5. Exporta los datos a Excel cuando lo necesites

## Cómo funciona

- Los datos se guardan en `/data/equipos.json`
- Usa GitHub API para leer y escribir
- Soporta hasta 3 usuarios simultáneos (límite de API)
- Los datos se mantienen sincronizados entre dispositivos

## Tecnologías

- HTML5
- CSS3
- JavaScript Vanilla (sin frameworks)
- GitHub API (almacenamiento en la nube)
- Exportación a Excel

---

Desarrollado con ❤️

