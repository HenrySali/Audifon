@echo off
REM ============================================================================
REM  push_mvdr_tuning.bat  (spec mvdr-noise-clarity-tuning)
REM  Pushea a main SOLO los fuentes del spec (C++, Kotlin, Dart, tests, spec).
REM  NO incluye binarios (.exe), obj/, build/, .gradle, .dart_tool, .cxx.
REM  Correr en CMD.
REM ============================================================================
setlocal
cd /d "C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\Audifon"

echo ============================================
echo  Branch actual:
git rev-parse --abbrev-ref HEAD
echo ============================================
echo.

echo [1/5] Staging de fuentes...
REM --- C++ nucleo DSP ---
git add android/app/src/main/cpp/audio_engine.h
git add android/app/src/main/cpp/dsp_pipeline.cpp
git add android/app/src/main/cpp/dsp_pipeline.h
git add android/app/src/main/cpp/environment_classifier.cpp
git add android/app/src/main/cpp/environment_classifier.h
git add android/app/src/main/cpp/mvdr_beamformer.h
git add android/app/src/main/cpp/native_bridge.cpp
git add android/app/src/main/cpp/expander.h
git add android/app/src/main/cpp/smart_scene/noise_profile.cpp
git add android/app/src/main/cpp/smart_scene/noise_profile.h
git add android/app/src/main/cpp/smart_scene/scene_analyzer.cpp
git add android/app/src/main/cpp/smart_scene/scene_analyzer.h
REM --- Tests (solo .cpp y .bat, NO .exe ni obj/) ---
git add android/app/src/main/cpp/tests/compat_defaults_test.cpp
git add android/app/src/main/cpp/tests/dereverb_ab_test.cpp
git add android/app/src/main/cpp/tests/expander_test.cpp
git add android/app/src/main/cpp/tests/mpo_invariant_test.cpp
git add android/app/src/main/cpp/tests/run_mvdr_tuning_tests.bat
git add android/app/src/main/cpp/smart_scene/tests/test_noise_scale.cpp
git add android/app/src/main/cpp/smart_scene/tests/test_scene_convergence.cpp
REM --- Kotlin (cadena nativa) ---
git add android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt
git add android/app/src/main/kotlin/com/psk/hearing_aid_app/NativeAudioBridge.kt
REM --- Dart (bridges + fix Flutter 3.19.6) ---
git add lib/data/bridges/audio_bridge.dart
git add lib/data/bridges/audio_bridge_impl.dart
git add lib/presentation/screens/loopback_qc_screen.dart
REM --- Spec completo (requirements/design/research/tasks/notas/.bat) ---
git add ".kiro/specs/mvdr-noise-clarity-tuning/requirements.md"
git add ".kiro/specs/mvdr-noise-clarity-tuning/design.md"
git add ".kiro/specs/mvdr-noise-clarity-tuning/research.md"
git add ".kiro/specs/mvdr-noise-clarity-tuning/tasks.md"
git add ".kiro/specs/mvdr-noise-clarity-tuning/.config.kiro"
git add ".kiro/specs/mvdr-noise-clarity-tuning/mpo-ucl-propagation-note.md"
git add ".kiro/specs/mvdr-noise-clarity-tuning/build_apk_mvdr_tuning.bat"
git add ".kiro/specs/mvdr-noise-clarity-tuning/install_apk_mvdr_tuning.bat"
git add ".kiro/specs/mvdr-noise-clarity-tuning/push_mvdr_tuning.bat"

echo.
echo [2/5] Archivos staged:
git status --short --untracked-files=no
echo.

echo [3/5] Commit...
git commit -m "feat(mvdr-noise-clarity-tuning): expander R1, fix escala ruido/SNR R2, clasificador R4, dereverb R5, tests + spec; fix Flutter 3.19.6 en loopback_qc"
if errorlevel 1 ( echo *** No se pudo commitear (nada staged o error). *** & exit /b 1 )

echo.
echo [4/5] Pull --rebase (por si hay commits remotos)...
git pull --rebase origin main
if errorlevel 1 (
    echo *** CONFLICTO en rebase. Resuelve manualmente y luego: git rebase --continue ; git push ***
    exit /b 1
)

echo.
echo [5/5] Push a main...
git push origin main
if errorlevel 1 ( echo *** FALLO el push. Revisa credenciales/red. *** & exit /b 1 )

echo.
echo ============================================
echo  PUSH OK a main. GitHub Actions compilara el APK.
echo ============================================
endlocal
