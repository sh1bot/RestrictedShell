@echo off
setlocal
if "%~2"=="" (
  echo Usage: build-one.bat ARCH OUTPUT
  exit /b 2
)
set "ARCH=%~1"
set "OUT=%~2"

where cl >nul 2>nul || (
  echo ERROR: cl.exe not found after selecting %ARCH% toolchain.
  exit /b 1
)

cl /nologo /c /std:c++17 /O1 /GL /GS- /GR- /Zl RestrictedShell.cpp /Fo:RestrictedShell-%ARCH%.obj
if errorlevel 1 exit /b %errorlevel%

link /nologo RestrictedShell-%ARCH%.obj kernel32.lib user32.lib gdi32.lib ole32.lib advapi32.lib ^
 /SUBSYSTEM:WINDOWS /ENTRY:entry /NODEFAULTLIB ^
 /OPT:REF /OPT:ICF /LTCG /MERGE:.rdata=.text ^
 /OUT:"%OUT%"
exit /b %errorlevel%
