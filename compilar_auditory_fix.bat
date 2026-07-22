@echo off
REM ============================================================================
REM  compilar_auditory_fix.bat — Compila APK con fix del Modelo Auditivo
REM  (Etapas 5-6 removidas: ya no destruyen el audio)
REM ============================================================================
setlocal
set "FLUTTER=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\flutter_3196\bin\flutter.bat"
set "PROJ=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\Audifon"

cd /d "%PROJ%"

echo ============================================
echo  FIX: AuditoryModel stages 5-6 removed
echo  (IHC rect + AN envelope destruian el audio)
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
echo  BUILD OK. APK en:
echo   build\app\outputs\flutter-apk\app-debug.apk
echo.
echo  Instalar con:
echo   install_apk_mvdr_fix.bat
echo ============================================
endlocal
