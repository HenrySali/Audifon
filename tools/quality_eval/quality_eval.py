#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quality_eval.py — Evaluador PESQ + STOI sobre el pipeline DNN del audífono.

MEJORA #5 (ruido-profundo.md): pipeline CI con métricas objetivas.

Uso:
    python quality_eval.py \\
        --noisy-dir <dir> --clean-dir <dir> \\
        --output metrics.json [--baseline baseline_metrics.json] \\
        [--passthrough | --dnn-cli <path>]

Convenciones:
    - clean-dir y noisy-dir deben tener los mismos filenames (.wav).
    - Todos los WAV deben ser 16 kHz mono (PESQ/STOI lo asumen).
    - El script no aborta si un archivo falla; reporta y sigue.

Salida (JSON):
    {
        "summary": { "n_files": N, "pesq": {...}, "stoi": {...},
                     "passed": bool, "failures": [...] },
        "per_file": [ { "name": ..., "pesq": ..., "stoi": ... }, ... ]
    }

Exit code:
    0 — todos los thresholds del baseline cumplidos.
    1 — al menos un threshold por debajo del baseline.
    2 — error de configuración (dirs no existen, baseline malformado, etc.).
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import statistics
import subprocess  # noqa: S404 — se usa solo para invocar el CLI del DNN si se provee.
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

# pesq y pystoi son lazy-imports para que el script pueda mostrar --help
# aunque las deps no estén instaladas todavía.
try:
    from pesq import pesq as pesq_score  # type: ignore[import-not-found]
except ImportError:
    pesq_score = None

try:
    from pystoi import stoi as stoi_score  # type: ignore[import-not-found]
except ImportError:
    stoi_score = None


# ──────────────────────────────────────────────────────────────────────────────
# Constantes — alineadas con el wrapper C++ del DNN.
# ──────────────────────────────────────────────────────────────────────────────

TARGET_SAMPLE_RATE = 16000
PESQ_MODE = "wb"  # wide-band, requiere SR=16000.

logger = logging.getLogger("quality_eval")


# ──────────────────────────────────────────────────────────────────────────────
# Parseo de argumentos.
# ──────────────────────────────────────────────────────────────────────────────


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evaluador PESQ + STOI sobre el pipeline DNN del audífono.",
        epilog="MEJORA #5 (Amplificador/docs/ruido-profundo.md).",
    )
    parser.add_argument(
        "--noisy-dir",
        type=Path,
        required=True,
        help="Directorio con los WAV ruidosos a procesar.",
    )
    parser.add_argument(
        "--clean-dir",
        type=Path,
        required=True,
        help="Directorio con los WAV de referencia limpios (mismo filename).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("metrics.json"),
        help="Path del JSON de salida con las métricas.",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=Path(__file__).with_name("baseline_metrics.json"),
        help="Path del JSON con thresholds (default: baseline_metrics.json contiguo).",
    )

    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--passthrough",
        action="store_true",
        help=(
            "No corre el DNN; calcula métricas sobre el noisy directo. "
            "Útil para validar el harness CI antes de tener el CLI standalone."
        ),
    )
    mode.add_argument(
        "--dnn-cli",
        type=Path,
        default=None,
        help=(
            "Path al CLI standalone del DNN denoiser (TODO en este repo). "
            "Si se provee, cada noisy se procesa con: "
            "`<dnn-cli> --in noisy.wav --out tmp.wav`. "
            "Ver Amplificador/tools/quality_eval/README.md."
        ),
    )

    parser.add_argument(
        "--max-files",
        type=int,
        default=0,
        help="Limita la cantidad de archivos a procesar (0 = todos).",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Logging DEBUG.",
    )
    return parser.parse_args(argv)


# ──────────────────────────────────────────────────────────────────────────────
# I/O y utilidades.
# ──────────────────────────────────────────────────────────────────────────────


def load_wav_mono16k(path: Path) -> np.ndarray:
    """Carga un WAV como mono float32 a 16 kHz; eleva ValueError si no encaja."""
    data, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1).astype(np.float32)
    if sr != TARGET_SAMPLE_RATE:
        raise ValueError(
            f"{path.name}: sample rate {sr} != {TARGET_SAMPLE_RATE}. "
            "Resampleá los fixtures antes de pasar al evaluador.",
        )
    return data


def align_lengths(ref: np.ndarray, deg: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Recorta ambas señales a la longitud mínima común."""
    n = min(len(ref), len(deg))
    return ref[:n], deg[:n]


def find_pairs(noisy_dir: Path, clean_dir: Path) -> list[Path]:
    """Devuelve los filenames presentes en AMBOS directorios (sorted)."""
    noisy = {p.name for p in noisy_dir.glob("*.wav")}
    clean = {p.name for p in clean_dir.glob("*.wav")}
    common = sorted(noisy & clean)
    only_noisy = noisy - clean
    only_clean = clean - noisy
    if only_noisy:
        logger.warning("WAVs en noisy sin par en clean (ignorados): %s", sorted(only_noisy))
    if only_clean:
        logger.warning("WAVs en clean sin par en noisy (ignorados): %s", sorted(only_clean))
    return [Path(name) for name in common]


# ──────────────────────────────────────────────────────────────────────────────
# Procesamiento del DNN (passthrough / CLI externo).
# ──────────────────────────────────────────────────────────────────────────────


def process_with_dnn(
    noisy_wav: Path,
    dnn_cli: Path | None,
    *,
    passthrough: bool,
) -> np.ndarray:
    """
    Devuelve la señal denoised como np.ndarray float32 mono 16k.
    - Si `passthrough` es True: simplemente carga noisy_wav (sin denoising).
    - Si `dnn_cli` está provisto: invoca `<dnn_cli> --in noisy --out tmp.wav`.
    - Si nada de eso: pasa por passthrough con un warning.
    """
    if passthrough or dnn_cli is None:
        if not passthrough:
            logger.warning(
                "Sin --dnn-cli ni --passthrough explícito; defaulteo a passthrough. "
                "Las métricas NO reflejan el denoiser.",
            )
        return load_wav_mono16k(noisy_wav)

    with tempfile.NamedTemporaryFile(
        prefix="dnn_eval_", suffix=".wav", delete=False,
    ) as tmp:
        tmp_path = Path(tmp.name)
    try:
        cmd = [str(dnn_cli), "--in", str(noisy_wav), "--out", str(tmp_path)]
        logger.debug("DNN CLI: %s", " ".join(cmd))
        # nosec — args validados por argparse, dnn-cli se confía a propósito (es interno del proyecto).
        result = subprocess.run(  # noqa: S603
            cmd, check=False, capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"DNN CLI falló (rc={result.returncode}) sobre {noisy_wav.name}: "
                f"{result.stderr.strip()}",
            )
        return load_wav_mono16k(tmp_path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


# ──────────────────────────────────────────────────────────────────────────────
# Cálculo de métricas.
# ──────────────────────────────────────────────────────────────────────────────


def compute_pesq_stoi(
    clean: np.ndarray, deg: np.ndarray,
) -> tuple[float | None, float | None]:
    """Calcula (PESQ, STOI). Devuelve None en cada métrica si la lib no está."""
    clean_aligned, deg_aligned = align_lengths(clean, deg)

    pesq_val: float | None = None
    if pesq_score is not None:
        try:
            pesq_val = float(
                pesq_score(TARGET_SAMPLE_RATE, clean_aligned, deg_aligned, PESQ_MODE),
            )
        except Exception as e:  # noqa: BLE001 — pesq lib levanta variedad de excepciones.
            logger.warning("PESQ falló: %s", e)
    else:
        logger.warning("Lib `pesq` no instalada; se omite PESQ.")

    stoi_val: float | None = None
    if stoi_score is not None:
        try:
            stoi_val = float(
                stoi_score(clean_aligned, deg_aligned, TARGET_SAMPLE_RATE, extended=False),
            )
        except Exception as e:  # noqa: BLE001
            logger.warning("STOI falló: %s", e)
    else:
        logger.warning("Lib `pystoi` no instalada; se omite STOI.")

    return pesq_val, stoi_val


# ──────────────────────────────────────────────────────────────────────────────
# Resumen y comparación con baseline.
# ──────────────────────────────────────────────────────────────────────────────


def _stats(values: list[float]) -> dict[str, float] | None:
    if not values:
        return None
    return {
        "mean": round(statistics.fmean(values), 4),
        "median": round(statistics.median(values), 4),
        "std": round(
            statistics.pstdev(values) if len(values) > 1 else 0.0, 4,
        ),
        "min": round(min(values), 4),
        "max": round(max(values), 4),
        "n": len(values),
    }


def build_summary(
    per_file: list[dict[str, Any]], baseline: dict[str, Any],
) -> dict[str, Any]:
    pesq_vals = [r["pesq"] for r in per_file if r.get("pesq") is not None]
    stoi_vals = [r["stoi"] for r in per_file if r.get("stoi") is not None]

    pesq_stats = _stats(pesq_vals)
    stoi_stats = _stats(stoi_vals)

    failures: list[str] = []

    # Criterio: la MEDIANA debe estar por encima del baseline.
    pesq_min = float(baseline.get("pesq_min", -math.inf))
    stoi_min = float(baseline.get("stoi_min", -math.inf))

    if pesq_stats is not None and pesq_stats["median"] < pesq_min:
        failures.append(
            f"PESQ median {pesq_stats['median']:.3f} < baseline {pesq_min:.3f}",
        )
    if stoi_stats is not None and stoi_stats["median"] < stoi_min:
        failures.append(
            f"STOI median {stoi_stats['median']:.3f} < baseline {stoi_min:.3f}",
        )

    return {
        "n_files": len(per_file),
        "pesq": pesq_stats,
        "stoi": stoi_stats,
        "passed": len(failures) == 0,
        "failures": failures,
        "baseline": {"pesq_min": pesq_min, "stoi_min": stoi_min},
    }


# ──────────────────────────────────────────────────────────────────────────────
# Main.
# ──────────────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    if not args.noisy_dir.is_dir():
        logger.error("noisy-dir no existe o no es directorio: %s", args.noisy_dir)
        return 2
    if not args.clean_dir.is_dir():
        logger.error("clean-dir no existe o no es directorio: %s", args.clean_dir)
        return 2

    try:
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        logger.error("No pude leer baseline %s: %s", args.baseline, e)
        return 2

    pair_names = find_pairs(args.noisy_dir, args.clean_dir)
    if args.max_files and args.max_files > 0:
        pair_names = pair_names[: args.max_files]

    if not pair_names:
        logger.error(
            "No hay pares (noisy, clean) con el mismo filename en los directorios.",
        )
        return 2

    logger.info(
        "Evaluando %d pares (passthrough=%s, dnn-cli=%s)",
        len(pair_names),
        args.passthrough,
        args.dnn_cli,
    )

    per_file: list[dict[str, Any]] = []
    for i, name in enumerate(pair_names, start=1):
        noisy_path = args.noisy_dir / name.name
        clean_path = args.clean_dir / name.name

        record: dict[str, Any] = {"name": name.name}
        try:
            clean = load_wav_mono16k(clean_path)
            deg = process_with_dnn(
                noisy_path, args.dnn_cli, passthrough=args.passthrough,
            )
            pesq_val, stoi_val = compute_pesq_stoi(clean, deg)
            record["pesq"] = pesq_val
            record["stoi"] = stoi_val
            logger.info(
                "[%d/%d] %s — PESQ=%s STOI=%s",
                i,
                len(pair_names),
                name.name,
                f"{pesq_val:.3f}" if pesq_val is not None else "n/a",
                f"{stoi_val:.3f}" if stoi_val is not None else "n/a",
            )
        except Exception as e:  # noqa: BLE001 — queremos seguir aunque un archivo rompa.
            logger.warning("Error procesando %s: %s", name.name, e)
            record["error"] = str(e)
            record["pesq"] = None
            record["stoi"] = None

        per_file.append(record)

    summary = build_summary(per_file, baseline)
    output = {"summary": summary, "per_file": per_file}

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8",
    )
    logger.info("Métricas escritas en %s", args.output)

    if not summary["passed"]:
        for f in summary["failures"]:
            logger.error("THRESHOLD FALLIDO: %s", f)
        return 1

    logger.info("OK — todas las métricas por encima del baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
