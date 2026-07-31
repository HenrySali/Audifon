@echo off
REM ============================================================================
REM run_mvdr_tuning_tests.bat
REM Compila y corre los tests unitarios del spec mvdr-noise-clarity-tuning:
REM   - expander_test          (R1 — Expansor de baja frecuencia)
REM   - dereverb_ab_test       (R5 — toggle del dereverb MVDR)
REM   - compat_defaults_test   (R6 — toggles nuevos en OFF == pre-spec)
REM   - mpo_invariant_test     (R7 — invariante de seguridad clínica MPO)
REM   - ..\smart_scene\tests\test_noise_scale (R2 — fix de escala del ruido)
REM
REM Requiere MSVC (vcvars64). Host build — NO usa Android NDK ni Oboe.
REM ============================================================================
setlocal
REM Posicionarse en la carpeta del propio script (funciona aunque se ejecute
REM desde System32 o cualquier otro directorio).
cd /d "%~dp0"
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo ERROR: vcvars64.bat no encontrado en "%VCVARS%"
    echo Ajusta la ruta VCVARS a tu instalacion de Visual Studio Build Tools.
    exit /b 1
)
call "%VCVARS%" >nul
if errorlevel 1 ( echo ERROR cargando entorno MSVC. & exit /b 1 )

if not exist obj mkdir obj
set "FAIL=0"

echo(
echo ===== R1: expander_test (header-only) =====
cl /std:c++17 /EHsc /O2 /nologo /W3 /D_USE_MATH_DEFINES /I.. expander_test.cpp ^
    /Fe:expander_test.exe /Fo:obj\ || set "FAIL=1"
if exist expander_test.exe ( expander_test.exe || set "FAIL=1" )

echo(
echo ===== R5: dereverb_ab_test (header-only) =====
cl /std:c++17 /EHsc /O2 /nologo /W3 /D_USE_MATH_DEFINES /I.. dereverb_ab_test.cpp ^
    /Fe:dereverb_ab_test.exe /Fo:obj\ || set "FAIL=1"
if exist dereverb_ab_test.exe ( dereverb_ab_test.exe || set "FAIL=1" )

echo(
echo ===== R6: compat_defaults_test (pipeline) =====
cl /std:c++17 /EHsc /O2 /nologo /W3 /D_USE_MATH_DEFINES /I.. compat_defaults_test.cpp ^
    ..\dsp_pipeline.cpp ..\noise_reduction.cpp ..\equalizer.cpp ^
    ..\wdrc_processor.cpp ..\mpo_limiter.cpp ..\environment_classifier.cpp ^
    ..\spectrum_analyzer.cpp ..\transient_reducer.cpp ^
    /Fe:compat_defaults_test.exe /Fo:obj\ || set "FAIL=1"
if exist compat_defaults_test.exe ( compat_defaults_test.exe || set "FAIL=1" )

echo(
echo ===== R7: mpo_invariant_test (pipeline) =====
cl /std:c++17 /EHsc /O2 /nologo /W3 /D_USE_MATH_DEFINES /I.. mpo_invariant_test.cpp ^
    ..\dsp_pipeline.cpp ..\noise_reduction.cpp ..\equalizer.cpp ^
    ..\wdrc_processor.cpp ..\mpo_limiter.cpp ..\environment_classifier.cpp ^
    ..\spectrum_analyzer.cpp ..\transient_reducer.cpp ^
    /Fe:mpo_invariant_test.exe /Fo:obj\ || set "FAIL=1"
if exist mpo_invariant_test.exe ( mpo_invariant_test.exe || set "FAIL=1" )

echo(
echo ===== R2: test_noise_scale (smart_scene) =====
pushd ..\smart_scene\tests
if not exist obj mkdir obj
cl /std:c++17 /EHsc /O2 /nologo /W3 /D_USE_MATH_DEFINES /I.. test_noise_scale.cpp ^
    ..\spectral_features.cpp ..\noise_profile.cpp ..\vad_detector.cpp ^
    ..\scene_analyzer.cpp ^
    /Fe:test_noise_scale.exe /Fo:obj\ || set "FAIL=1"
if exist test_noise_scale.exe ( test_noise_scale.exe || set "FAIL=1" )
popd

echo(
if "%FAIL%"=="0" ( echo ===== TODOS LOS TESTS PASARON ===== ) else ( echo ===== HUBO FALLOS ===== )
exit /b %FAIL%
