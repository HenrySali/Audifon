@echo off
REM ============================================================================
REM  install_apk_mvdr_fix.bat  (Repo Oir Pro3)
REM  Instala el APK ya compilado en el Moto G32 (ZY22GTNVGN) via adb.
REM  Conecta el telefono por USB con depuracion USB activada.
REM ============================================================================
setlocal
cd /d "%~dp0"

set "ADB=C:\Users\Elsa y Henry\AppData\Local\Android\sdk\platform-tools\adb.exe"
set "APK=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro3\Audifon\build\app\outputs\flutter-apk\app-debug.apk"

if not exist "%ADB%" (
    echo ERROR: adb no encontrado en "%ADB%".
    exit /b 1
)
if not exist "%APK%" (
    echo ERROR: APK no encontrado. Compila primero con build_apk_mvdr_fix.bat
    exit /b 1
)

echo Dispositivos conectados:
"%ADB%" devices
echo.

echo Instalando APK (-r reinstala conservando datos)...
"%ADB%" install -r "%APK%"
if errorlevel 1 (
    echo *** FALLO LA INSTALACION - revisa cable/depuracion USB. ***
    exit /b 1
)

echo.
echo ============================================
echo  INSTALACION OK. Abre la app, activa el modo MVDR y prueba.
echo ============================================
endlocal
