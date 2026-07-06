@echo off
setlocal
cd /d "C:\Users\Elsa y Henry\Desktop\Amplificador\Repo Oir Pro2\Audifon"

echo Pull --rebase origin main...
git pull --rebase origin main
echo.
echo Push origin main...
git push origin main
echo.
echo Estado final:
git log --oneline -3
endlocal
