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

cl /nologo /c /std:c++17 /O1 /GL /GS /guard:cf /GR- /Zl RestrictedShell.cpp /Fo:RestrictedShell-%ARCH%.obj
if errorlevel 1 exit /b %errorlevel%

cl /nologo /c /std:c++17 /O1 /GL /GS- /GR- /Zl SecurityEntry.cpp /Fo:SecurityEntry-%ARCH%.obj
if errorlevel 1 exit /b %errorlevel%

link /nologo RestrictedShell-%ARCH%.obj SecurityEntry-%ARCH%.obj ^
 kernel32.lib user32.lib gdi32.lib ole32.lib advapi32.lib ^
 libvcruntime.lib bufferoverflowU.lib ^
 /SUBSYSTEM:WINDOWS /ENTRY:secure_entry /NODEFAULTLIB ^
 /DYNAMICBASE /NXCOMPAT /guard:cf ^
 /OPT:REF /OPT:ICF /LTCG ^
 /OUT:"%OUT%"
exit /b %errorlevel%
