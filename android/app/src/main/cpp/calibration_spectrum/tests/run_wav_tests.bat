@echo off
REM Compila y ejecuta los tests de validación contra WAV pre-renderizados.
REM Los WAV se generan en out_wavs/ (gitignoreado).

setlocal

set VCVARS="C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist %VCVARS% (
    echo ERROR: vcvars64.bat no encontrado
    exit /b 1
)
call %VCVARS% >nul

cl /nologo /EHsc /std:c++17 /W3 /O2 ^
    /I.. ^
    ..\fft_engine.cpp ^
    ..\peak_detector.cpp ^
    ..\thd_calculator.cpp ^
    ..\tone_analyzer.cpp ^
    test_wav_validation.cpp ^
    /Fetest_wav_validation.exe ^
    /link /SUBSYSTEM:CONSOLE

if errorlevel 1 (
    echo.
    echo ERROR de compilacion.
    exit /b 2
)

echo.
echo === Ejecutando WAV validation tests ===
test_wav_validation.exe out_wavs
set TEST_EXIT=%errorlevel%

del /q *.obj 2>nul

exit /b %TEST_EXIT%
