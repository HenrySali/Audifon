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



---

## Sesión 2 — 3 julio 2026

### Lo que se implementó

**Sistema de recomendaciones contextuales de audio (20 detecciones):**

Widget `AudioRecommendationWidget` en la pantalla principal que monitorea condiciones de audio en tiempo real y muestra banners con sugerencias accionables:

| # | Detección | Patrón | Acción |
|---|-----------|--------|--------|
| 1 | Eco/feedback | Nivel alto + agudos altos sin voz (8s) | Reducir agudos -5 dB |
| 2 | Voz baja | SPEECH + nivel <45 dB (10s) | Subir volumen +3 dB |
| 3 | Saturación EQ | 3+ bandas cerca del MPO | Reducir todo -3 dB |
| 4 | Nivel muy bajo | <25 dB por 20s | Informativo (mic check) |
| 5 | Clipping | >90 dB sostenido 6s | Reducir volumen -5 dB |
| 6 | MPO limitando | Output pegado al techo 8s | Reducir ganancias |
| 7 | DNN matando voz | SPEECH + NR≥3 + nivel >55 (10s) | Bajar NR |
| 8 | Roce de ropa/chasquido | Spikes >15 dB repetidos sin voz (6s) | Activar TNR |
| 9 | Ganancia asimétrica | >15 dB diferencia graves/agudos | Informativo |
| 10 | Música | Espectro amplio + sin voz (16s) | Activar Modo Música |
| 11 | Viento | Energía en graves + NOISE (8s) | Cortar graves -8 dB |
| 12 | Fatiga auditiva | Sesión >2 horas | Informativo (descanso) |
| 13 | Volumen al máximo | +10 dB por 10s | Informativo (recalibrar) |
| 14 | NR insuficiente | NOISE + NR≤1 (10s) | Subir NR |
| 15 | Perfil estático | >15 min sin cambiar | Activar Smart |
| 16 | Exposición alta | LEQ sesión >80 dB | Reducir volumen |
| 17-20 | Ambiente (conversación/ruido/silencio) | Clasificador estable 6s | Cambiar perfil |

**Integración con Hermes:**
- Cada detección se envía automáticamente como observación a Hermes (`[Auto] ...`)
- El texto incluye telemetría (nivel, gains, perfil, NR) para que la IA genere ajustes precisos
- Si `autoApply=true` → Hermes aplica solo
- Si `autoApply=false` → aparece como sugerencia en la ventana de Hermes
- Cooldown de 60s por tipo para no spamear el VPS (independiente del cooldown visual de 30s)

### Archivos modificados
- `lib/presentation/widgets/audio_recommendation_widget.dart` — widget nuevo (completo)
- `lib/presentation/screens/main_screen.dart` — import + integración en `_ActiveView`

### Commits
- `ab5b34b` — feat: add contextual audio recommendation popups
- `290982b` — fix: add missing MethodChannel import
- `70e2fff` — feat: connect audio detections to Hermes adaptive learning
- `904a104` — feat: expand recommendations to 20 detection types

### Pendiente para próxima sesión
- Probar las 20 detecciones en campo (Moto G32)
- Verificar que el roce de ropa se detecta correctamente (bolsillo, mesa)
- Confirmar que Hermes recibe las observaciones [Auto] y genera sugerencias coherentes
- Duplicar el widget a la app de usuario (`Audifon-usuario`) si funciona bien
- Subir el server-patch.js al VPS (pendiente de sesión anterior)
- Probar slider SPL Offset en supermercado (pendiente de sesión anterior)
- Evaluar si bajar los tiempos de detección para testing (ej: 4s en vez de 10s para voz baja)
