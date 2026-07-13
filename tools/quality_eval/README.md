# Quality Eval — PESQ + STOI sobre el pipeline DNN

> **MEJORA #5 (ruido-profundo.md):** validación CI automática del denoiser GTCRN.
>
> Este tool calcula PESQ (calidad percibida) y STOI (inteligibilidad) sobre pares
> `(noisy, clean)` y compara contra un baseline mínimo. Bloquea regresiones antes
> de mergear cambios al pipeline DSP.

## Métricas

| Métrica | Rango | Significado |
|---------|-------|-------------|
| **PESQ** (Perceptual Evaluation of Speech Quality, ITU-T P.862) | -0.5 a 4.5 | Calidad percibida. >2.5 es buena, >3.0 es excelente. |
| **STOI** (Short-Time Objective Intelligibility) | 0 a 1 | Inteligibilidad. >0.85 es comprensible, >0.95 es nativa. |
| HASPI / HASQI (TODO) | 0 a 1 | Métricas específicas de audífonos del Clarity Challenge. Requieren `pyclarity`, que tiene deps pesadas (PyTorch + librosa). Se evalúa como follow-up. |

## Thresholds (baseline_metrics.json)

```json
{
  "pesq_min": 2.7,
  "stoi_min": 0.91
}
```

Estos son los valores que el equipo de DSP definió como aceptables tras el
benchmark inicial sobre VoiceBank+DEMAND. Si una PR baja PESQ o STOI por debajo
del threshold, el workflow CI falla.

## Estructura del directorio de evaluación

El script espera dos directorios paralelos con el mismo set de filenames:

```
test_set/
├── clean/
│   ├── p232_001.wav
│   ├── p232_002.wav
│   └── ...
└── noisy/
    ├── p232_001.wav    # mismo nombre, mezclado con ruido
    ├── p232_002.wav
    └── ...
```

Todos los WAV deben ser:
- 16 kHz, mono, PCM 16-bit
- Aproximadamente la misma duración entre el par clean y noisy

## Uso

### Local

```bash
cd Amplificador/tools/quality_eval
python -m venv .venv
source .venv/bin/activate          # Linux / macOS
.venv\Scripts\activate             # Windows

pip install -r requirements.txt

python quality_eval.py \
    --noisy-dir /path/to/test_set/noisy \
    --clean-dir /path/to/test_set/clean \
    --output metrics.json \
    --baseline baseline_metrics.json
```

Output esperado (`metrics.json`):

```json
{
  "summary": {
    "n_files": 30,
    "pesq": { "mean": 2.91, "std": 0.18, "min": 2.55, "max": 3.34 },
    "stoi": { "mean": 0.93, "std": 0.02, "min": 0.89, "max": 0.97 },
    "passed": true,
    "failures": []
  },
  "per_file": [
    { "name": "p232_001.wav", "pesq": 2.88, "stoi": 0.92 },
    ...
  ]
}
```

Exit code:
- `0` si pasa todos los thresholds.
- `1` si alguna métrica de la mediana queda por debajo del baseline.

### CI

El workflow `.github/workflows/dsp-quality.yml` ejecuta este script automáticamente
en cada PR que toque `Amplificador/hearing_aid_app/android/app/src/main/cpp/dnn_denoiser/`.

## Estado del pipeline DNN para evaluación

> **TODO** — Hoy el DNN denoiser corre solo dentro del APK Android (no hay CLI
> standalone que tome un WAV y devuelva el WAV procesado). Para que este script
> sea útil de verdad, necesitamos:
>
> 1. **Opción A — CLI standalone:** crear `Amplificador/tools/dnn_cli/dnn_cli.py`
>    que cargue `gtcrn.onnx` con `onnxruntime` y procese un WAV con la misma
>    pre/post (resample + STFT 512/128 + cache recurrente) que el wrapper C++.
>    Recomendado.
> 2. **Opción B — Bridge JNI:** instrumentar la app con un modo "offline batch"
>    que tome WAVs del sandbox de la app y emita los procesados. Más invasivo.
>
> Mientras se decide, el script soporta el flag `--passthrough` que **omite el
> denoising** y solo calcula PESQ/STOI sobre el `noisy` directo. Esto permite
> validar que el harness CI funciona, aunque las métricas no reflejen el DNN.

## Datasets recomendados

| Dataset | Tamaño | Uso |
|---------|--------|-----|
| VoiceBank+DEMAND test set (824 archivos) | ~250 MB | Default; el GTCRN paper reporta WB-PESQ 2.93 sobre este. |
| Clarity Challenge ICASSP 2023 eval set | ~5 GB | Específico para audífonos (HRTF + reverb). Pesado para CI. |
| Subset propio del proyecto (30 archivos) | ~30 MB | Lo que está en `tests/fixtures/dnn_eval/` (recomendado). |

Para CI usar el subset propio (30 archivos) — corre en < 2 minutos. Para release
candidate validar contra VoiceBank+DEMAND completo localmente.

## Referencias

- ITU-T P.862 — PESQ algorithm
- Taal et al. 2011 — STOI: Short-Time Objective Intelligibility Measure
- `pesq` package: <https://pypi.org/project/pesq/>
- `pystoi` package: <https://pypi.org/project/pystoi/>
- `pyclarity` (HASPI/HASQI, TODO): <https://github.com/claritychallenge/clarity>
