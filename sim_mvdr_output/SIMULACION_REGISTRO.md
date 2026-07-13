# Registro de Simulación DSP — 2026-07-07

## Herramientas
- Python 3.11 + NumPy 2.0.2 + SciPy 1.13.1 + pyroomacoustics 0.10.1
- Entorno: Kiro sandbox (Linux)

## Dispositivo target
- Motorola Moto G32
- Mic spacing: 16 cm (bottom-to-top)
- Sample rate: 48 kHz
- SPL offset: 93 dB

## Simulaciones realizadas

### 1. MVDR — Aliasing espacial (commit dc89e0d)
- **Sala:** 5x4x3 m, RT60=0.4s, 4 interferencias
- **Resultado:** SDR -2.3 dB (peor que bypass)
- **Causa:** Aliasing a 1071 Hz con 16 cm spacing
- **Decisión:** MVDR descartado para uso diario

### 2. Pipeline completo — 5 escenarios (commit e3f1793)
- Silencio: 60.9 dB salida, 0 clips ✓
- Voz sola: SDR 10.2 dB, modulación 0.986 ✓
- Voz + 4 personas: SDR 8.1 dB, modulación 0.973 ✓
- Ruido fuerte: 64.1 dB salida, 0 clips ✓
- Música: 76.4 dB salida, bypass ✓

### 3. Slider intensidad DNN (commit 07be2b8)
- 0% a 100%: voz pierde máximo -2.5 dB (imperceptible)
- Modulación >0.88 en todo el rango
- Sin artefactos de comb filtering

### 4. Anti-tartamudeo e impulsos (commit 8028250)
- TNR threshold 3.0, atenuación -18 dB
- Pops: 63 → 3 (95% eliminados)
- Tartamudeos: 0
- Voz no dañada (correlación >0.85)

### 5. MPO saturation — input 89.8 dB (este commit)
- **Problema real:** MPO limita 28% con postWdrc 102.4 dB
- **Causa:** EQ max +20 dB sobre input 89.8 dB = picos >110 dB
- **Fix:** Gain scaling adaptativo (reduce EQ cuando input >70 dB)
- **Fórmula:** `scale = min(1.0, (MPO - 6 - inputLevel) / maxEqGain)`
- **Resultado:** MPO 0% con scale 0.38

## Parámetros validados finales
| Parámetro | Valor | Validación |
|-----------|-------|-----------|
| DNN DD alpha | 0.7 | Preserva onsets |
| DNN piso ganancia | -12 dB | Sin musical noise |
| DNN onset boost | 3x threshold | Anti-tartamudeo |
| DNN suavizado | 0.7 | Natural |
| TNR threshold | 3.0 | 95% pops eliminados |
| TNR atenuación | -18 dB | Sin daño a voz |
| EQ gain scale | adaptativo | MPO no satura |
| WDRC knee | 52 dB (voz) | ScenePolicy |
| MPO threshold | 110 dB SPL | FDA OTC |
