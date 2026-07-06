@echo off
setlocal
cd /d "C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\Audifon"

echo Branch actual:
git rev-parse --abbrev-ref HEAD
echo.

echo Staging cambios A (soft-knee MPO) y B (piso de ruido real)...
git add android/app/src/main/cpp/mpo_limiter.h
git add android/app/src/main/cpp/mpo_limiter.cpp
git add android/app/src/main/cpp/dsp_pipeline.h
git add android/app/src/main/cpp/dsp_pipeline.cpp
git add android/app/src/main/cpp/smart_scene/scene_analyzer.cpp
git add android/app/src/main/cpp/smart_scene/noise_profile.h
git add android/app/src/main/cpp/smart_scene/noise_profile.cpp
git add android/app/src/main/cpp/tests/mpo_invariant_test.cpp
git add android/app/src/main/cpp/smart_scene/tests/test_noise_scale.cpp
git add ".kiro/specs/mvdr-noise-clarity-tuning/tasks.md"
git add ".kiro/specs/mvdr-noise-clarity-tuning/finish_push.bat"
git add ".kiro/specs/mvdr-noise-clarity-tuning/push_AB.bat"
echo.

echo Archivos staged:
git status --short --untracked-files=no
echo.

echo Commit...
git commit -m "fix(mvdr-tuning): soft-knee MPO anti-ronquera + compensacion de sesgo Martin 2001 en piso de ruido (no pegado en -60); tests verdes"
echo.

echo Pull --rebase origin main...
git pull --rebase origin main
echo.

echo Push origin main...
git push origin main
echo.

echo Estado final:
git log --oneline -3
endlocal
