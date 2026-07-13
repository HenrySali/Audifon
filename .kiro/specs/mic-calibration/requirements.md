# Requirements Document

## Spec: Calibración del Micrófono y Extensión de la Calibración Biológica

> Spec orientado a la certificación regulatoria del audífono digital pediátrico/adulto V2 (nRF5340 + Zephyr + Flutter) en **Argentina (ANMAT)** y **Colombia (INVIMA)**, con armonización Mercosur y soporte para mercados internacionales.
>
> Spec ID: `mic-calibration`
> Fecha: 2 de junio de 2026.

## Introduction

El audífono digital V2 ya tiene un sistema de calibración biológica del lado de **salida** (auriculares) implementado bajo `lib/biological_calibration/`, basado en el método Hughson-Westlake (ANSI S3.21 / ISO 8253-1). Sin embargo:

1. **Falta calibración del lado de entrada** (micrófono ICS-43434 → dB SPL real). Sin esa calibración, la conversión `dBFS → dB SPL` usa offsets heurísticos (76, 93, 120 dB) que no corresponden al device real, lo que afecta:
   - La activación correcta de la región de expansión del WDRC.
   - La referencia de niveles en el clasificador de entorno.
   - La medición de SPL ambiente.
   - La protección MPO en términos de SPL absoluto.
2. **Falta trazabilidad regulatoria**: para certificar el producto como dispositivo médico Clase II en Argentina (ANMAT Disposición 2318/2002) y Colombia (Decreto 4725 de 2005, Clase IIa típica), todas las calibraciones deben tener audit trail, vinculación a estándares técnicos reconocidos y documentación trazable a un laboratorio acreditado bajo ISO 17025.
3. **Falta diferenciación entre calibración de fábrica y calibración de campo**: la calibración de producción se hace en laboratorio acreditado con acoplador 2cc (IEC 60318-5), mientras que la calibración de campo la realiza el clínico/operador con el dispositivo en uso real.

Este spec extiende el módulo `biological_calibration` existente y crea nuevos componentes para la calibración del micrófono, manteniendo todo coherente con el marco regulatorio LATAM.

## Glossary

- **ANMAT** — Administración Nacional de Medicamentos, Alimentos y Tecnología Médica (Argentina). Autoridad regulatoria sanitaria.
- **INVIMA** — Instituto Nacional de Vigilancia de Medicamentos y Alimentos (Colombia). Autoridad regulatoria sanitaria.
- **Mercosur** — Mercado Común del Sur (Argentina, Brasil, Paraguay, Uruguay). Tiene resoluciones armonizadas para dispositivos médicos.
- **OAA** — Organismo Argentino de Acreditación. Acredita laboratorios bajo ISO 17025.
- **INTI** — Instituto Nacional de Tecnología Industrial (Argentina). Laboratorio oficial de ensayos.
- **dBFS** — Decibelios relativos al fondo de escala digital (`0 dBFS = ±1.0` en float).
- **dB SPL** — Decibelios relativos al nivel de presión sonora de referencia (20 µPa).
- **dB HL** — Decibelios relativos al umbral medio audiométrico de adultos jóvenes con audición normal (ANSI S3.6, ISO 389).
- **AOP** — Acoustic Overload Point. Para ICS-43434 = 120 dB SPL.
- **RECD** — Real-Ear-to-Coupler Difference. Diferencia entre el SPL en el oído real y el SPL en un acoplador 2cc.
- **RETSPL** — Reference Equivalent Threshold Sound Pressure Level. Tabla en ANSI S3.6 que define el cero audiométrico.
- **Acoplador 2cc** — Acoplador acústico estándar (IEC 60318-5) usado para mediciones de audífonos.
- **HWA** — Hughson-Westlake Algorithm. Método clínico estándar para audiometría tonal.
- **MEMS** — Micro-Electro-Mechanical System (tecnología del micrófono ICS-43434).
- **SaMD** — Software as a Medical Device (clasificación de software regulado).
- **QMS** — Quality Management System (ISO 13485 para dispositivos médicos).

## Regulatory Compliance Framework

### Argentina — ANMAT

- **Disposición ANMAT 2318/2002 (TO 2004)**: regula el registro de productos médicos. Los audífonos digitales se clasifican como **Clase II** ([ANMAT — PHONAK audífono RITE Clase II](https://helena.anmat.gob.ar/uploads/pdfs/dc_59511_30536071802_3177.pdf?rnd=4194a987-e2b9-4d3c-9836-9cb4df8bad74)).
- **Reconocimiento IEC 60601 e IEC 61010**: ANMAT acepta certificados de ensayo emitidos por laboratorios oficiales como **INTI** o privados acreditados bajo **ISO 17025** por la **OAA** ([ANMAT — Tramites productos médicos eléctricos](http://www.anmat.gob.ar/webanmat/tecmed/productos/productos.asp)).
- **Disposición ANMAT 727/2013 — Buenas Prácticas de Fabricación (BPF)**: equivale a ISO 13485 para dispositivos médicos (cita pendiente de profundizar).
- **Página oficial**: [ANMAT Productos Médicos](https://www.argentina.gob.ar/anmat/regulados/productos-medicos).
- **Plazo legal de evaluación**: 180 días corridos (en práctica 12-18 meses) ([Thema-Med Argentina](http://www.thema-med.com/es/registrar-un-dispositivo-medico-en-argentina/)).
- **Importadores deben designar AAR** (Authorized Argentine Representative).

### Colombia — INVIMA

- **Decreto 4725 de 2005** (Ministerio de Salud y Protección Social): régimen de registros sanitarios, permiso de comercialización y vigilancia sanitaria de dispositivos médicos ([Decreto 4725 oficial](https://www.minsalud.gov.co/sites/rid/lists/bibliotecadigital/ride/de/dij/decreto-4725-de-2005.pdf), [Función Pública](https://www.funcionpublica.gov.co/eva/gestornormativo/norma.php?i=18697)).
- **Clasificación**: clases I, IIA, IIB, III según riesgo (artículo 5° y 7°) basado en duración del contacto con el cuerpo, grado de invasión, efecto local vs sistémico ([SUIN-Juriscol](https://www.suin-juriscol.gov.co/viewDocument.asp?id=1549782)).
- **Audífonos digitales** generalmente caen en **Clase IIa** (uso prolongado externo, acción local, no invasivo).
- **INVIMA — Dispositivos Médicos Equipos Biomédicos**: trámites y formularios oficiales ([INVIMA portal](https://www.invima.gov.co/productos-vigilados/dispositivos-medicos/dispositivos-medicos-equipos-biomedicos)).
- **Decreto 3770 de 2004** + **Decreto 4725**: normativa armonizada vigente. En revisión hacia un nuevo régimen unificado ([Invitro News — Nuevo modelo regulatorio](https://invitronews.com/de-los-decretos-4725-y-3770-hacia-un-nuevo-modelo-regulatorio-de-dispositivos-medicos-y-reactivos-de-diagnostico-in-vitro/)).
- **NTC IEC 60601** (Norma Técnica Colombiana adoptada del IEC).

### Mercosur (armonización regional)

- **GMC/RES 25/2020** y derivadas: armonización de regulación de dispositivos médicos entre países miembros (cita a profundizar en bloque siguiente).
- Las normas IEC adoptadas por Argentina (vía IRAM) y Colombia (vía NTC) son las mismas en su contenido técnico.

### Normas técnicas internacionales armonizadas (aplicables en ambos países)

| Norma | Cubre | Estado en Argentina | Estado en Colombia |
|---|---|---|---|
| **ISO 13485** | Sistema de gestión de calidad para dispositivos médicos | Equivalente a Disp. ANMAT 727/2013 BPF | Adoptada vía NTC |
| **ISO 14971** | Gestión de riesgos del dispositivo médico | Reconocida | Reconocida |
| **IEC 62304** | Software de dispositivo médico (clases A/B/C) | Reconocida | Reconocida |
| **IEC 60601-1** | Seguridad eléctrica del equipo médico | IRAM IEC 60601-1, ensayo INTI/OAA | NTC IEC 60601-1 |
| **IEC 60601-1-2** | Compatibilidad electromagnética (EMC) | Reconocida | Reconocida |
| **IEC 62366-1** | Ingeniería de usabilidad | Reconocida | Reconocida |
| **ANSI/ASA S3.22-2014 (R2020)** | Características electroacústicas del audífono | Reconocida (vía IEC 60118-7) | Reconocida (vía IEC 60118-7) |
| **IEC 60118-0 / 60118-7 / 60118-15** | Mediciones de audífonos, ISTS | Reconocida | Reconocida |
| **ANSI S3.6 / ISO 389** | RETSPL audiométrico | Reconocida | Reconocida |
| **ANSI S3.21 / ISO 8253-1** | Hughson-Westlake | Reconocida | Reconocida |
| **IEC 60318-5 / IEC 60318-1** | Acopladores 2cc / ear simulator | Reconocida | Reconocida |
| **ISO 17025** | Acreditación de laboratorios de ensayo | OAA (Argentina) | ONAC (Colombia) |
| **IEC 61672-1 / ANSI S1.4** | Sonómetros (no aplicable a smartphone solo) | Aplica solo si hay mic externo certificado | Idem |

## Requirements

### Requirement 1: Calibración del Micrófono — Persistencia por Device

**User Story:** Como técnico clínico, quiero que la calibración del micrófono se persista por modelo de dispositivo (deviceModel + deviceId), para que cada teléfono Android use el offset correcto sin tener que recalibrar manualmente cada vez.

#### Acceptance Criteria

1. WHEN el sistema arranca THEN THE app SHALL leer el offset SPL persistido en Hive box `mic_calibration_box` y aplicarlo via `nativeSetSplOffset()` antes de iniciar el pipeline DSP.
2. WHEN el usuario completa una calibración manual o automática del mic THEN THE app SHALL guardar `MicCalibrationResult` con `{deviceId, deviceModel, splOffset, calibrationDate, method, qualityFlags}` en `mic_calibration_box`.
3. WHEN el usuario cambia de dispositivo Android (otro modelo) THEN THE app SHALL detectar via `Build.MODEL` y solicitar recalibración antes de habilitar el pipeline DSP completo.
4. IF no existe calibración persistida para el deviceModel actual THEN THE app SHALL aplicar un offset por defecto conservador (93 dB) y mostrar una alerta no-bloqueante recomendando calibrar.
5. WHEN el offset persistido tiene más de 12 meses de antigüedad THEN THE app SHALL mostrar advertencia recomendando recalibración (alineado con prácticas BPF de revalidación periódica).

### Requirement 2: Calibración Manual del Micrófono via Slider

**User Story:** Como operador clínico sin acceso a generador de tonos certificado, quiero ajustar manualmente el offset SPL con un slider numérico, para tener una calibración funcional rápida (no certificable) en escenarios de campo.

#### Acceptance Criteria

1. WHILE el usuario está en `MicCalibrationScreen` modo "Manual" THE app SHALL mostrar un slider de offset entre 60 dB y 130 dB con paso de 0.5 dB.
2. WHILE el usuario mueve el slider THE app SHALL mostrar en tiempo real el SPL actualmente medido por el mic con el offset propuesto.
3. WHEN el usuario confirma con botón "Guardar" THEN THE app SHALL persistir el resultado y aplicarlo al pipeline.
4. THE UI SHALL mostrar un disclaimer visible: "Calibración manual de campo. No reemplaza calibración certificada en laboratorio acreditado ISO 17025 (INTI, ONAC u OAA)."

### Requirement 3: Calibración Automática del Micrófono via Tono de Referencia

**User Story:** Como operador clínico con acceso a un sonómetro o tono de referencia conocido, quiero que la app capture y mida automáticamente para calcular el offset, para una calibración funcional más precisa que la manual.

#### Acceptance Criteria

1. WHEN el usuario inicia "Calibración Automática" THEN THE app SHALL pedir al operador que reproduzca un tono de 1 kHz a un nivel SPL conocido (ej: 94 dB SPL desde sonómetro calibrado o calibrador acústico).
2. WHEN el operador presiona "Capturar" THEN THE app SHALL medir el RMS de 5 segundos de tono y calcular `splOffset = SPL_referencia - 20·log10(rms_capturado)`.
3. WHILE la captura está en curso THE app SHALL mostrar nivel en vivo y verificar que el tono detectado esté dentro de ±5% de 1 kHz (Quinn 2nd-order frequency estimator existente).
4. IF la frecuencia detectada está fuera de tolerancia OR el nivel detectado tiene clipping THEN THE app SHALL abortar la calibración y mostrar error explicativo.
5. WHEN la calibración se completa con éxito THEN THE app SHALL guardar `method = automatic_tone`, junto con la frecuencia detectada, RMS y SPL de referencia ingresado.

### Requirement 4: Audit Trail Completo (Trazabilidad Regulatoria)

**User Story:** Como Authorized Argentine Representative (AAR) o titular del registro INVIMA, necesito que cada sesión de calibración deje un registro auditable, para cumplir con los requisitos de trazabilidad de ANMAT 2318/02 y Decreto 4725/2005.

#### Acceptance Criteria

1. WHEN ocurre cualquier evento de calibración (inicio, captura, guardar, fallo, recargar) THEN THE app SHALL registrar una entrada en `calibration_audit_box` con `{timestamp ISO 8601, event_type, operator_id, device_id, device_model, app_version, firmware_version, result_summary, sha256_of_result}`.
2. WHEN el usuario solicita exportar el audit trail THEN THE app SHALL generar un archivo JSON firmado o un PDF con la lista cronológica completa.
3. WHILE el audit trail box exceda 10000 entradas THE app SHALL rotar manteniendo las últimas 8000 + un archivo de archivo histórico exportable.
4. THE audit trail SHALL ser inmutable desde la UI (no se puede editar, solo consultar y exportar).

### Requirement 5: Extensión de la Calibración Biológica para Incluir el Lado de Entrada

**User Story:** Como diseñador del producto, quiero que la calibración biológica existente incluya también el mapeo SPL→dBFS del lado del micrófono (no solo HL→dBFS del lado del audífono), para tener una calibración bilateral completa en una sola sesión clínica.

#### Acceptance Criteria

1. THE existing model `BiologicalCalibrationResult` SHALL be extended with optional field `inputCalibration: MicCalibrationResult?` sin romper la persistencia de calibraciones existentes.
2. WHEN el operador completa la rutina Hughson-Westlake del lado de salida THEN THE app SHALL ofrecer continuar inmediatamente con la calibración del mic en la misma sesión.
3. WHEN ambas calibraciones se completan THEN THE app SHALL persistirlas atómicamente (transacción única en Hive) bajo la misma `subjectSession`.
4. IF la calibración del mic falla THEN THE app SHALL preservar la calibración biológica de salida sin rollback.

### Requirement 6: Cuestionario de Elegibilidad Pre-Calibración

**User Story:** Como audiólogo, quiero que el cuestionario de elegibilidad existente (`eligibility_questionnaire.dart`) se aplique también antes de la calibración del mic cuando hay sujeto humano involucrado, para cumplir con buenas prácticas clínicas.

#### Acceptance Criteria

1. WHEN el operador inicia una calibración con sujeto humano (modo "biológica extendida") THEN THE app SHALL mostrar el `EligibilityQuestionnaire` antes de proceder.
2. IF el sujeto no cumple criterios de elegibilidad THEN THE app SHALL impedir el inicio de la calibración y registrarlo en audit trail.
3. WHEN el modo es "field calibration" sin sujeto humano (solo equipo) THEN THE app SHALL omitir el cuestionario y registrar en audit trail que se trató de calibración técnica.

### Requirement 7: Catch Trials para Control de Calidad

**User Story:** Como auditor regulatorio, quiero que la calibración biológica extendida mantenga el sistema de catch trials existente, para detectar respuestas no confiables del sujeto.

#### Acceptance Criteria

1. THE existing `CatchTrialScheduler` SHALL apply during the audiometric portion of the extended biological calibration unchanged.
2. IF la tasa de falsos positivos en catch trials supera 30% THEN THE app SHALL marcar la sesión como "calidad cuestionable" en `qualityFlags` del resultado.
3. WHEN qualityFlags incluye "calidad cuestionable" THEN THE export del resultado SHALL incluir la advertencia visible en la primera línea.

### Requirement 8: Modo "Production Calibration" vs "Field Calibration"

**User Story:** Como ingeniero de QC en planta, necesito un modo "Production Calibration" diferente al modo "Field Calibration", para hacer la calibración de fábrica con acoplador 2cc bajo entorno controlado y trazable a INTI / ONAC.

#### Acceptance Criteria

1. THE app SHALL exponer dos modos seleccionables: `production` (fábrica) y `field` (clínica/usuario).
2. WHEN el modo es `production` THEN THE app SHALL requerir credenciales de operador autorizado y exigir conexión con un sonómetro Tipo 2 (IEC 61672) externo via Bluetooth o USB.
3. WHEN el modo es `production` THEN THE audit trail SHALL incluir lote de fabricación, número de serie del PCB, ID del sonómetro de referencia y fecha de calibración del sonómetro.
4. WHEN el modo es `field` THEN THE app SHALL mostrar disclaimer claro de que la calibración es funcional, no certificada para producción.

### Requirement 9: Importación / Exportación de Datos de Calibración

**User Story:** Como clínico que mueve pacientes entre sedes o como auditor, quiero importar y exportar resultados de calibración biológica completa (salida + entrada), para portabilidad y trazabilidad regulatoria.

#### Acceptance Criteria

1. WHEN el usuario selecciona "Exportar Calibración" THEN THE app SHALL generar un archivo JSON con esquema versionado (`schemaVersion: "2.0"`) que incluya `BiologicalCalibrationResult` extendido + `auditTrail` filtrado a esa sesión.
2. WHEN el usuario selecciona "Importar Calibración" THEN THE app SHALL validar el schemaVersion, la firma SHA-256 del payload, y mostrar diff con la calibración actual antes de aplicar.
3. IF el deviceModel del JSON importado no coincide con el actual THEN THE app SHALL bloquear la importación y mostrar advertencia clara.

### Requirement 10: Soporte Multidispositivo y Multiusuario

**User Story:** Como clínica que tiene varios dispositivos Android compartidos por audiólogos, quiero que la app diferencie calibraciones por device + por operador, para que cada combinación tenga su propia calibración persistida.

#### Acceptance Criteria

1. THE persistence key for mic calibration SHALL be `(deviceId + deviceModel + operatorId)` cuando el operatorId está disponible, o `(deviceId + deviceModel)` cuando no.
2. WHEN el operador cambia su login THEN THE app SHALL recargar la calibración asociada a su operatorId si existe; caso contrario fallback a la del device.
3. WHEN no hay sistema de login implementado THEN THE app SHALL operar en modo single-user con `operatorId = "default"`.

### Requirement 11: Validación con Acoplador 2cc en Producción

**User Story:** Como ingeniero de validación de planta, quiero que la calibración de producción se valide contra mediciones en acoplador 2cc según IEC 60318-5, para que el certificado de ensayo emitido por INTI / ONAC sea trazable.

#### Acceptance Criteria

1. WHEN el modo es `production` THEN THE app SHALL guiar al operador a colocar el dispositivo en el acoplador 2cc IEC 60318-5 antes de iniciar el sweep de frecuencias.
2. WHEN se ejecuta el sweep THEN THE app SHALL medir respuesta de frecuencia en bandas estándar ANSI S3.22 (250, 500, 1000, 1600, 2500, 4000 Hz) y registrar OSPL90, FOG, RTG.
3. THE resultado SHALL ser comparado contra la especificación del producto y rechazado si excede ±5 dB de la curva de referencia o ±3% en cualquier punto crítico (por ahora valores tentativos, ajustar según hoja de datos final).
4. WHEN la calibración es aceptada THEN THE app SHALL imprimir un certificado QR-firmado que un inspector ANMAT / INVIMA pueda verificar.

### Requirement 12: Disclaimer de Cumplimiento en UI

**User Story:** Como Quality Manager, quiero que la app comunique correctamente al usuario cuándo la calibración es funcional y cuándo es certificada, para evitar reclamaciones regulatorias.

#### Acceptance Criteria

1. WHILE el usuario está en cualquier pantalla de calibración del módulo THE app SHALL mostrar el disclaimer: "Calibración funcional. Para certificación regulatoria se requiere medición en laboratorio acreditado ISO 17025 (INTI / ONAC)."
2. WHEN el usuario está en modo `production` con sonómetro certificado conectado THEN THE disclaimer SHALL incluir la cita exacta del estándar referenciado (ej: "Medición conforme IEC 60318-5 + ANSI S3.22-2014").
3. THE disclaimer SHALL estar disponible en español argentino y español neutro / colombiano.

## Correctness Properties (PBT)

Para validación con tests de propiedades:

1. **PROPIEDAD A — Idempotencia de persistencia**: para cualquier `MicCalibrationResult r`, `load(save(r)) == r` modulo timestamp normalizado.
2. **PROPIEDAD B — Conversión bidireccional dBFS↔SPL**: para cualquier `dBFS` y `splOffset`, `dbfsFromSpl(splFromDbfs(dbfs, offset), offset) ≈ dbfs ± 0.001`.
3. **PROPIEDAD C — Monotonicidad del slider**: si `slider1 < slider2`, entonces el `splOffset` aplicado al pipeline reportará `level1_dB_SPL < level2_dB_SPL` para la misma señal de entrada.
4. **PROPIEDAD D — Audit trail crece monotónicamente**: para cualquier evento E, `auditTrail.size after E > auditTrail.size before E`, salvo en eventos de rotación documentados.
5. **PROPIEDAD E — Rango válido de offset**: el `splOffset` persistido SIEMPRE está en `[60, 130]` dB. Cualquier intento de persistir fuera de rango SHALL ser rechazado.
6. **PROPIEDAD F — Atomicidad de calibración bilateral**: si la calibración bilateral falla a mitad, el estado persistido es exactamente uno de: (todo guardado), o (nada guardado de esta sesión). No estados parciales.
7. **PROPIEDAD G — Compatibilidad de schemaVersion**: cualquier export con `schemaVersion = "2.0"` es legible por el código actual; cualquier export con schemaVersion < 2.0 se rechaza con mensaje claro.
