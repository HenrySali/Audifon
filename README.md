# 📋 Sistema de Relevamiento de Equipos

Aplicación web colaborativa para registrar y gestionar equipos con sus certificados. Los datos se sincronizan en tiempo real a través de GitHub y es totalmente responsive.

## Características

✅ **Ingreso de Equipos**
- Número de Serie
- Clase/Tipo de Equipo
- Estado del Certificado (Sí/No)
- Número de Piso (1, 2, 3)

✅ **Importación de Excel**
- Importa archivos Excel directamente
- Opción de reemplazar o agregar equipos existentes
- Validación automática del formato

✅ **Exportación a Excel**
- Exportar a archivo Excel (XLS)
- Incluye fecha de ingreso y exportación
- Compatible con Microsoft Excel y Google Sheets

✅ **Sincronización en GitHub**
- Todos los usuarios ven los mismos datos
- Sincronización automática desde cualquier dispositivo
- Datos persistentes en el repositorio

✅ **Diseño Responsive**
- Funciona perfectamente en móvil, tablet y desktop
- Tabla optimizada para pantallas pequeñas
- Interfaz intuitiva y fácil de usar

✅ **Gestión de Datos**
- Lista completa de equipos registrados
- Eliminar equipos individuales
- Estado de conexión en tiempo real

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

**Ingresar equipos:**
1. Completa los campos del formulario
2. Haz clic en "Agregar Equipo"
3. Los datos se guardan automáticamente en GitHub

**Exportar Excel:**
1. Haz clic en "📊 Exportar a Excel"
2. Se descargará un archivo con todos los equipos

**Importar Excel:**
1. Haz clic en "📥 Importar Excel"
2. Selecciona un archivo Excel (formato: Número de Serie, Clase de Equipo, Certificado, Piso)
3. Elige si deseas reemplazar o agregar equipos
4. Los datos se sincronizarán automáticamente

## Cómo funciona

- Los datos se guardan en `/data/equipos.json`
- Usa GitHub API para leer y escribir
- Soporta hasta 3 usuarios simultáneos (límite de API)
- Los datos se mantienen sincronizados entre dispositivos
- Diseño completamente responsive para cualquier tamaño de pantalla

## Formato de Excel para importar

El archivo debe tener estas columnas exactamente:
| Número de Serie | Clase de Equipo | Certificado | Piso |
|---|---|---|---|
| SN123456789 | Monitor | Sí | Piso 1 |
| SN987654321 | CPU | No | Piso 2 |

## Tecnologías

- HTML5
- CSS3
- JavaScript Vanilla (sin frameworks)
- GitHub API (almacenamiento en la nube)
- XLSX.js para lectura/escritura de Excel
- Diseño responsive con Media Queries

---

Desarrollado con ❤️

