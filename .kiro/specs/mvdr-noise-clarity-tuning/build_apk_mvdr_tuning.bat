@echo off
REM ============================================================================
REM  build_apk_mvdr_tuning.bat  (spec mvdr-noise-clarity-tuning, tarea 6.2)
REM
REM  Compila el APK del TECNICO (incluye el .so nativo hearing_aid_dsp con los
REM  cambios del spec: Expander R1, fix de escala R2, clasificador R4, dereverb
REM  R5). El paciente CLONA el C++ del tecnico, asi que este build valida la
REM  cadena C++ -> Kotlin -> Dart de ambos.
REM
REM  === IMPORTANTE (RAM) ===
REM  El build del .so + LibTorch/ONNX consume mucha memoria. El agente NO lo
REM  corre por falta de RAM. Antes de ejecutar este .bat:
REM    1. Cerra Android Studio, emuladores, navegadores y apps pesadas.
REM    2. Corre este .bat en una consola CMD (no PowerShell) desde tu PC.
REM    3. Si falla por memoria (Java heap / OOM), reintenta con menos apps
REM       abiertas o agrega  org.gradle.jvmargs=-Xmx2g  en android/gradle.properties.
REM
REM  Verificacion de host (rapida, sin RAM del .so) — correr ANTES:
REM    android\app\src\main\cpp\tests\run_mvdr_tuning_tests.bat
REM ============================================================================
setlocal

set "FLUTTER=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\flutter_3196\bin\flutter.bat"
set "PROJ=C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\Audifon"

if not exist "%FLUTTER%" (
    echo ERROR: flutter.bat no encontrado en "%FLUTTER%".
    echo Ajusta la variable FLUTTER a tu instalacion.
    exit /b 1
)

cd /d "%PROJ%"

echo ============================================
echo  Branch actual:
git rev-parse --abbrev-ref HEAD
echo ============================================
echo.

echo [1/2] dart analyze (informativo, NO bloquea)...
REM flutter analyze devuelve codigo !=0 incluso con solo warnings/info.
REM No bloqueamos el build por eso: los errores reales de compilacion los
REM atrapa "flutter build apk" mas abajo. Este paso queda como referencia.
REM IMPORTANTE: se usa "call" porque flutter.bat es un .bat; sin call el
REM control NO regresa a este script y se cortaria aqui.
call "%FLUTTER%" analyze
echo.
echo (analyze terminado - warnings/info NO detienen el build)
echo.

echo [2/2] Compilando APK debug (arm64) + .so nativo...
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
echo  Instalar con INSTALAR_APK.bat o "%FLUTTER%" install
echo ============================================
endlocal
