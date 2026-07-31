@echo off
setlocal
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo ERROR: vcvars64.bat no encontrado en "%VCVARS%"
    exit /b 1
)
call "%VCVARS%" >nul
if errorlevel 1 (
    echo ERROR cargando entorno MSVC.
    exit /b 1
)

if not exist obj mkdir obj

cl /std:c++17 /EHsc /O2 /nologo /W3 /I.. ^
    test_vad.cpp ^
    ..\spectral_features.cpp ^
    ..\noise_profile.cpp ^
    ..\vad_detector.cpp ^
    ..\scene_analyzer.cpp ^
    /Fe:test_vad.exe /Fo:obj\\
if errorlevel 1 (
    echo ERROR de compilacion.
    exit /b 1
)

echo.
echo ========== Ejecutando tests ==========
test_vad.exe
exit /b %errorlevel%
