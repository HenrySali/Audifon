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
