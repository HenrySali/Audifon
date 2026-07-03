# Registro de Sesiones

## Sesión 1 — 1 julio 2026

### Problema detectado
- El paciente reporta "radio mal sintonizado" con DNN al 100% en el supermercado
- Diagnóstico: el clasificador de entorno dice QUIET cuando debería decir SPEECH_IN_NOISE
- Causa raíz: el `splOffset` del micrófono está en 120 pero el Moto G32 necesita ~140
- Con offset incorrecto, el nivel reportado es 44 dB SPL cuando la realidad es ~65 dB SPL
- Al clasificar como QUIET, el VAD no se activa → el DNN no baja su agresividad → mata los agudos

### Solución implementada
- Slider SPL Offset en Servicio Técnico para ajustar manualmente (rango 90-160)
- Se persiste en Hive y se aplica automáticamente al boot

### Otras mejoras de esta sesión
- App usuario: desbloqueo de modo técnico con clave `741852` (iconos ocultos hasta ingresar la clave)
- Ambas apps: conexión del Aprendizaje Adaptativo al VPS real (149.50.137.2:8080)
- Ambas apps: toggle "Hermes aplica automáticamente" (ON = aplica solo, OFF = solo sugiere)
- VPS: instalado paquete `openai` en hermes-learning, configurada API key, aiEnabled=true

### Estado del VPS (hermes-learning)
- Corre en pm2 como `hermes-learning` en puerto 8080
- Endpoints: POST /api/adaptive-learning/analyze, POST /api/adaptive-learning/feedback, GET /health
- aiEnabled: true (OpenAI configurado)

### Pendiente para próxima sesión
- Probar el slider SPL Offset en el supermercado (poner en ~140 y verificar que el nivel reportado suba)
- Verificar que el clasificador cambie de QUIET a SPEECH_IN_NOISE con el offset correcto
- Verificar que Hermes responde con sugerencias desde la app
- Si el offset 140 no alcanza, probar 145-150
- Si todo funciona: mergear o confirmar conformidad
- Evaluar si crear un script de sincronización entre repos (técnico → usuario automático)
- Crear CHANGELOG.md formal para trazabilidad de versiones

### Repos y ramas
- `HenrySali/Audifon` (técnico) — main actualizado
- `HenrySali/Audifon-usuario` (usuario) — main actualizado
- `HenrySali/OirPro` (backend) — sin cambios en esta sesión

### Celular de prueba
- Motorola Moto G32, Android 13
- splOffset sugerido: ~140 (verificar en campo)


---

## Sesión 1 (continuación) — Hermes Colectivo

### Lo que se implementó

**Servidor Hermes v2 (archivo listo para subir al VPS):**
- Persistencia en disco de observaciones por dispositivo (`data/<deviceId>/observations.json`)
- Pool colectivo con todas las observaciones de todos los usuarios (`data/_collective/observations.json`)
- Endpoint GET `/api/adaptive-learning/history/:deviceId` — historial por dispositivo
- Endpoint GET `/api/adaptive-learning/collective-insights` — patrones cruzados entre usuarios
- Endpoint POST `/api/adaptive-learning/sync` — recuperación tras reinstalación
- El archivo está en `hermes-server-upgrade/server-patch.js` del repo Audifon

**App técnico:**
- Cada request a Hermes ahora envía `deviceId` (hex 16 chars, generado y persistido en Hive)
- Al abrir la app, sincroniza historial desde el VPS (recupera observaciones previas)
- Botón de historial (ícono reloj) que abre un modal con todos los ajustes aplicados
- Toggle "Hermes aplica automáticamente" persiste entre sesiones

### Para desplegar en el VPS

```bash
# Desde tu PC (copiar el server nuevo):
scp hermes-server-upgrade/server-patch.js root@149.50.137.2:"/var/www/OirPro K/adaptive-learning/server.js"

# En el VPS via SSH:
ssh root@149.50.137.2
mkdir -p "/var/www/OirPro K/adaptive-learning/data/_collective"
pm2 restart hermes-learning
curl http://localhost:8080/health
# Debe decir version: "2.0.0"
```

### Pendiente para próxima sesión
- Subir el server-patch.js al VPS y reiniciar Hermes
- Verificar que /health dice version 2.0.0
- Probar analyze con deviceId y verificar que persiste en data/
- Probar sync desde la app tras limpiar datos locales
- Duplicar cambios a la app de usuario (Audifon-usuario)
- Probar el slider SPL Offset en el supermercado (Moto G32, valor ~140)
- Evaluar script de sincronización automática entre repos
