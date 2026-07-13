@echo off
REM ============================================================================
REM  install_apk_mvdr_tuning.bat  (spec mvdr-noise-clarity-tuning)
REM  Instala el APK debug ya compilado en el Moto G32 (ZY22GTNVGN) via adb.
REM  Conecta el telefono por USB con depuracion USB activada antes de correr.
REM ============================================================================
setlocal
cd /d "%~dp0"

set "ADB=C:\Users\Elsa y Henry\AppData\Local\Android\sdk\platform-tools\adb.exe"
set "APK=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\Audifon\build\app\outputs\flutter-apk\app-debug.apk"

if not exist "%ADB%" (
    echo ERROR: adb no encontrado en "%ADB%". Ajusta la ruta ADB.
    exit /b 1
)
if not exist "%APK%" (
    echo ERROR: APK no encontrado en "%APK%".
    echo Compila primero con build_apk_mvdr_tuning.bat
    exit /b 1
)

echo ============================================
echo  Dispositivos conectados:
"%ADB%" devices
echo ============================================
echo.

echo Instalando APK (-r reinstala conservando datos)...
"%ADB%" install -r "%APK%"
if errorlevel 1 (
    echo.
    echo *** FALLO LA INSTALACION ***
    echo   - Verifica que el telefono este conectado y con depuracion USB ON.
    echo   - Si dice INSTALL_FAILED_UPDATE_INCOMPATIBLE, desinstala la app y reintenta.
    exit /b 1
)

echo.
echo ============================================
echo  INSTALACION OK. Abre la app en el Moto G32.
echo ============================================
endlocal
