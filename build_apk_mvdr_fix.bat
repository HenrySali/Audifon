@echo off
REM ============================================================================
REM  build_apk_mvdr_fix.bat  (Repo Oir Pro3)
REM  Compila el APK con los 4 fixes del MVDR (Fix#1 anti auto-cancelacion,
REM  Fix#2 post-filtro Wiener, Fix#3 loading adaptativo, Fix#4 dereverb suave).
REM  Cierra apps pesadas antes por RAM. Correr en CMD.
REM ============================================================================
setlocal
set "FLUTTER=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\flutter_3196\bin\flutter.bat"
set "PROJ=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro3\Audifon"

if not exist "%FLUTTER%" (
    echo ERROR: flutter.bat no encontrado en "%FLUTTER%".
    exit /b 1
)

cd /d "%PROJ%"

echo ============================================
echo  Branch actual:
git rev-parse --abbrev-ref HEAD
echo ============================================
echo.

echo [1/2] dart analyze (informativo, NO bloquea)...
call "%FLUTTER%" analyze
echo.
echo (analyze terminado - warnings/info NO detienen el build)
echo.

echo [2/2] Compilando APK debug (arm64) + .so nativo (MVDR con fixes)...
echo   (esto compila hearing_aid_dsp; asegura RAM libre)
call "%FLUTTER%" build apk --debug --target-platform android-arm64
if errorlevel 1 (
    echo.
    echo *** FALLO LA COMPILACION - probablemente RAM insuficiente ***
    echo     Cierra apps pesadas y reintenta.
    exit /b 1
)

echo.
echo ============================================
echo  BUILD OK. APK en:
echo   build\app\outputs\flutter-apk\app-debug.apk
echo  Instala con install_apk_mvdr_fix.bat
echo ============================================
endlocal
