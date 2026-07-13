@echo off
REM ============================================================================
REM  compilar_auditory_fix2.bat — Fix #2 del Modelo Auditivo
REM  - Etapa 1: ganancia reducida +6 dB (era +12), Q=0.8 (era 1.5)
REM  - Etapa 2: high-shelf -3 dB @4kHz (reemplaza BPF agresivo)
REM  - Etapa 3: REMOVIDA (gammatone BPF angosto generaba ruido resonante)
REM ============================================================================
setlocal
set "FLUTTER=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\flutter_3196\bin\flutter.bat"
set "PROJ=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\Audifon"

cd /d "%PROJ%"

echo ============================================
echo  FIX #2: AuditoryModel sin ruido de fondo
echo  - Peaking 2700Hz: +6dB Q=0.8 (suave)
echo  - Middle ear: high-shelf -3dB @4kHz
echo  - Gammatone BPF: REMOVIDO (causa raiz)
echo ============================================
echo.

echo Compilando APK debug (arm64)...
call "%FLUTTER%" build apk --debug --target-platform android-arm64
if errorlevel 1 (
    echo *** FALLO LA COMPILACION ***
    exit /b 1
)

echo.
echo ============================================
echo  BUILD OK. Instalar con install_apk_mvdr_fix.bat
echo ============================================
endlocal
