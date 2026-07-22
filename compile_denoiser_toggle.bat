@echo off
REM ============================================================================
REM  compile_denoiser_toggle.bat — Compila APK con DenoiserSelector toggle
REM  (spec ruidolimpio.md: RNNoise/DFN3/GTCRN exclusivo con crossfade)
REM ============================================================================
setlocal
set "FLUTTER=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\flutter_3196\bin\flutter.bat"
set "PROJ=C:\Users\Elsa y Henry\Desktop\Amplificador\Audifon-main (4)\Audifon-main"

if not exist "%FLUTTER%" (
    echo ERROR: flutter.bat no encontrado en "%FLUTTER%".
    exit /b 1
)

cd /d "%PROJ%"

echo ============================================
echo  DenoiserSelector Toggle Build
echo  (RNNoise / DFN3 / GTCRN exclusivo)
echo ============================================
echo.

echo [1/2] flutter analyze (informativo, NO bloquea)...
call "%FLUTTER%" analyze --no-fatal-infos --no-fatal-warnings
echo.

echo [2/2] Compilando APK debug (arm64) + .so nativo...
call "%FLUTTER%" build apk --debug --target-platform android-arm64
if errorlevel 1 (
    echo.
    echo *** FALLO LA COMPILACION ***
    echo     Revisa los errores arriba.
    exit /b 1
)

echo.
echo ============================================
echo  BUILD OK. APK en:
echo   %PROJ%\build\app\outputs\flutter-apk\app-debug.apk
echo ============================================
endlocal
