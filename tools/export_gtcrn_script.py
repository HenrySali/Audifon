#!/usr/bin/env python3
"""
export_gtcrn_script.py -- Re-exportar GTCRN_IVA con torch.jit.script
====================================================================

PROBLEMA: torch.jit.trace bakes shapes estaticas. El modelo trazado con
T=48000 crashea en Android con cualquier T diferente (SIGABRT en TORCH_CHECK).

SOLUCION: torch.jit.script compila el forward respetando la logica de control
(if/for/while) y permite shapes dinamicas en el eje temporal.

USO:
    cd H-GTCRN
    python ..\\Audifon\\tools\\export_gtcrn_script.py

REQUISITOS:
    - Python 3.8+
    - PyTorch 2.1.0 (mismo que el runtime Android)
    - El archivo gtcrn_iva.py en el directorio actual
    - El checkpoint best_model_0121.tar en el directorio actual

SALIDA:
    gtcrn_dual_scripted.pt  -- modelo con shapes dinamicas, compatible con
                              torch::jit::load() en Android (full JIT runtime)

DESPUES:
    Copiar gtcrn_dual_scripted.pt a:
    Audifon\\android\\app\\src\\main\\assets\\dnn_denoiser\\gtcrn_dual_mobile.pt
"""

import sys
import os
import torch

# ─── Verificar entorno ───────────────────────────────────────────────────────

print(f"PyTorch version: {torch.__version__}")
print(f"Working directory: {os.getcwd()}")

# Importar el modelo (debe estar en el directorio actual)
try:
    from gtcrn_iva import GTCRN_IVA
except ImportError:
    print("\nERROR: No se encuentra gtcrn_iva.py en el directorio actual.")
    print("Ejecutar este script desde la carpeta H-GTCRN")
    sys.exit(1)

# ─── Cargar checkpoint ───────────────────────────────────────────────────────

CHECKPOINT = "best_model_0121.tar"
if not os.path.exists(CHECKPOINT):
    print(f"\nERROR: No se encuentra {CHECKPOINT}")
    sys.exit(1)

print(f"Cargando checkpoint: {CHECKPOINT}")
checkpoint = torch.load(CHECKPOINT, map_location="cpu")

# Crear instancia del modelo
model = GTCRN_IVA()

# Cargar pesos (intentar ambos formatos comunes)
if "model_state_dict" in checkpoint:
    model.load_state_dict(checkpoint["model_state_dict"])
elif "state_dict" in checkpoint:
    model.load_state_dict(checkpoint["state_dict"])
else:
    # El checkpoint ES el state_dict directamente
    model.load_state_dict(checkpoint)

model.eval()
print("Modelo cargado OK")

# ─── Exportar con torch.jit.script ──────────────────────────────────────────

print("\nExportando con torch.jit.script (shapes dinámicas)...")

try:
    scripted = torch.jit.script(model)
except Exception as e:
    print(f"\nERROR en torch.jit.script: {e}")
    print("\nSi el error es por operaciones no soportadas por script,")
    print("hay que agregar type annotations al forward() del modelo.")
    print("Ver: https://pytorch.org/docs/stable/jit_language_reference.html")
    sys.exit(1)

# ─── Validar con diferentes valores de T ────────────────────────────────────

print("\nValidando con diferentes T (shapes dinámicas)...")

test_sizes = [128, 1024, 4800, 16000, 48000]
for T in test_sizes:
    try:
        with torch.no_grad():
            dummy = torch.randn(1, 2, T)
            out = scripted(dummy)
            if isinstance(out, torch.Tensor):
                print(f"  T={T:>6} -> output shape: {list(out.shape)} OK")
            elif isinstance(out, tuple):
                print(f"  T={T:>6} -> output[0] shape: {list(out[0].shape)} OK")
            else:
                print(f"  T={T:>6} -> output type: {type(out)}")
    except Exception as e:
        print(f"  T={T:>6} -> FALLO: {e}")
        print("\n  El modelo no soporta este T. Puede requerir que T sea")
        print("  múltiplo del hop_size interno (256).")

# ─── Guardar ─────────────────────────────────────────────────────────────────

OUTPUT_FILE = "gtcrn_dual_scripted.pt"
scripted.save(OUTPUT_FILE)
size_mb = os.path.getsize(OUTPUT_FILE) / (1024 * 1024)
print(f"\nGuardado: {OUTPUT_FILE} ({size_mb:.2f} MB)")

# ─── Instrucciones finales ───────────────────────────────────────────────────

print(f"""
====================================================================
SIGUIENTE PASO:

Copiar el modelo exportado a assets del proyecto:

  copy {OUTPUT_FILE} ..\\Audifon\\android\\app\\src\\main\\assets\\dnn_denoiser\\gtcrn_dual_mobile.pt

Luego rebuild:
  flutter build apk --release

====================================================================
""")
