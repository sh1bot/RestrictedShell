@echo off
setlocal EnableExtensions

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo ERROR: vswhere.exe not found. Install Visual Studio C++ build tools.
  exit /b 1
)

for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%I"
if not defined VS (
  echo ERROR: Visual Studio C++ tools not found.
  exit /b 1
)
set "VCVARS=%VS%\VC\Auxiliary\Build\vcvarsall.bat"

pushd "%~dp0"
for %%A in (x86 x64 arm64) do (
  echo.
  echo ==== Building %%A ====
  call "%VCVARS%" %%A >nul
  if errorlevel 1 goto :fail
  if not exist "..\bin\%%A" mkdir "..\bin\%%A"
  call build-one.bat %%A "..\bin\%%A\RestrictedShell.exe"
  if errorlevel 1 goto :fail
)
popd
echo.
echo Built x86, x64, and arm64 binaries under bin\.
exit /b 0

:fail
set "ERR=%ERRORLEVEL%"
popd
echo BUILD FAILED.
exit /b %ERR%
