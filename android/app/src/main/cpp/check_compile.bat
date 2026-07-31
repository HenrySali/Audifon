@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
if errorlevel 1 (
  call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
)
cd /d "C:\Users\Elsa y Henry\Desktop\Nueva carpeta (24)\Amplificador\hearing_aid_app\android\app\src\main\cpp"
cl.exe /c /EHsc /std:c++17 /W3 /I. wdrc_processor.cpp 2>&1
del wdrc_processor.obj 2>nul
