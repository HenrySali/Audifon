@echo off
REM Ejecuta los tests offline del motor C++ del Calibration Spectrum Validator.
REM Usa MSVC 2019 BuildTools si está instalado.

setlocal

set VCVARS="C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

if not exist %VCVARS% (
    echo ERROR: vcvars64.bat no encontrado en %VCVARS%
    exit /b 1
)

call %VCVARS% >nul

REM Compilar todas las unidades + el test runner. /EHsc para excepciones,
REM /std:c++17 para asegurar features, /W3 para advertencias razonables.
REM /Fe define el nombre del exe de salida.
cl /nologo /EHsc /std:c++17 /W3 /O2 ^
    /I.. ^
    ..\fft_engine.cpp ^
    ..\peak_detector.cpp ^
    ..\thd_calculator.cpp ^
    ..\tone_analyzer.cpp ^
    test_calibration_spectrum.cpp ^
    /Fetest_calibration_spectrum.exe ^
    /link /SUBSYSTEM:CONSOLE

if errorlevel 1 (
    echo.
    echo ERROR de compilacion.
    exit /b 2
)

echo.
echo === Ejecutando tests ===
test_calibration_spectrum.exe
set TEST_EXIT=%errorlevel%

REM Limpiar artefactos intermedios.
del /q *.obj 2>nul

exit /b %TEST_EXIT%
