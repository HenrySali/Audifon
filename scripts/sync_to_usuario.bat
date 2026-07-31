@echo off
REM =============================================================================
REM sync_to_usuario.bat — Sincroniza cambios del repo tecnico al repo usuario
REM
REM Uso:
REM   cd C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro4\Audifon
REM   scripts\sync_to_usuario.bat
REM
REM Prerequisitos:
REM   - Ambos repos clonados en la misma carpeta padre
REM   - Tecnico: ..\Audifon\
REM   - Usuario: ..\Audifon-usuario\
REM =============================================================================

setlocal enabledelayedexpansion

REM --- Configuracion ---
set "TECNICO=%~dp0.."
set "USUARIO=%TECNICO%\..\Audifon-usuario"

REM Verificar que existe el repo usuario
if not exist "%USUARIO%\.git" (
    echo [ERROR] No se encontro el repo usuario en: %USUARIO%
    echo         Asegurate de que Audifon-usuario esta clonado al lado de Audifon
    exit /b 1
)

echo.
echo ============================================================
echo  SYNC: Audifon (tecnico) --^> Audifon-usuario
echo ============================================================
echo.
echo  Origen:  %TECNICO%
echo  Destino: %USUARIO%
echo.

REM --- 1. C++ Nativo (todo el DSP) ---
echo [1/7] Sincronizando C++ nativo (DSP pipeline)...
robocopy "%TECNICO%\android\app\src\main\cpp" "%USUARIO%\android\app\src\main\cpp" /MIR /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1
echo       OK

REM --- 2. Modelos DNN ---
echo [2/7] Sincronizando modelos DNN...
robocopy "%TECNICO%\android\app\src\main\assets\dnn_denoiser" "%USUARIO%\android\app\src\main\assets\dnn_denoiser" /MIR /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1
echo       OK

REM --- 3. Librerias nativas (.so) ---
echo [3/7] Sincronizando librerias nativas (.so)...
robocopy "%TECNICO%\android\app\src\main\jniLibs" "%USUARIO%\android\app\src\main\jniLibs" /MIR /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1
echo       OK

REM --- 4. Domain layer (Dart) ---
echo [4/7] Sincronizando domain layer...
robocopy "%TECNICO%\lib\domain" "%USUARIO%\lib\domain" /MIR /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1
echo       OK

REM --- 5. Data bridges + services compartidos ---
echo [5/7] Sincronizando bridges y servicios...
copy /Y "%TECNICO%\lib\data\bridges\audio_bridge.dart" "%USUARIO%\lib\data\bridges\" >nul 2>&1
copy /Y "%TECNICO%\lib\data\bridges\audio_bridge_impl.dart" "%USUARIO%\lib\data\bridges\" >nul 2>&1
copy /Y "%TECNICO%\lib\data\services\adaptive_learning_service.dart" "%USUARIO%\lib\data\services\" >nul 2>&1
copy /Y "%TECNICO%\lib\data\services\remote_config_service.dart" "%USUARIO%\lib\data\services\" >nul 2>&1
echo       OK

REM --- 6. Scene engine ---
echo [6/7] Sincronizando scene engine...
robocopy "%TECNICO%\lib\scene" "%USUARIO%\lib\scene" /MIR /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1
echo       OK

REM --- 7. DNN controller (Dart) ---
echo [7/7] Sincronizando DNN controller...
robocopy "%TECNICO%\lib\dnn_denoiser" "%USUARIO%\lib\dnn_denoiser" /MIR /NFL /NDL /NJH /NJS /NC /NS >nul 2>&1
echo       OK

echo.
echo ============================================================
echo  SYNC COMPLETO
echo ============================================================
echo.
echo  Archivos sincronizados:
echo    - C++ DSP completo (pipeline, DNN, MVDR, etc.)
echo    - Modelos ONNX/PT
echo    - Librerias .so (arm64-v8a)
echo    - Domain layer (entities, prescriber, presets)
echo    - Audio bridge + adaptive learning service
echo    - Scene engine
echo    - DNN controller
echo.
echo  NO se sincronizo (tecnico-only):
echo    - Pantallas de calibracion/audiometria/servicio tecnico
echo    - lib/calibration_spectrum/
echo    - lib/biological_calibration/
echo    - lib/mic_calibration/
echo    - lib/bundle_export/
echo    - Herramientas de diagnostico
echo    - AI chat
echo.
echo  Siguiente paso:
echo    cd "%USUARIO%"
echo    git add -A
echo    git diff --stat
echo    git commit -m "sync: update from tecnico repo"
echo    git push
echo.

endlocal
