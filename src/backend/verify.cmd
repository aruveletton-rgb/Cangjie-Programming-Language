@echo off
rem One-command entry point that works regardless of which shell is on PATH.
rem Prefers PowerShell 7 on PATH, then the project-local portable copy.
setlocal
set "HERE=%~dp0"
for %%i in ("%HERE%..\..") do set "ROOT=%%~fi"
set "PWSH="
if exist "%ROOT%\temp\tools\pwsh\pwsh.exe" set "PWSH=%ROOT%\temp\tools\pwsh\pwsh.exe"
if not defined PWSH for %%i in (pwsh.exe) do set "PWSH=%%~$PATH:i"
if not defined PWSH (
  echo [ERROR] PowerShell 7 ^(pwsh^) not found.
  echo.
  echo   Extract the portable zip so that this file exists:
  echo     %ROOT%\temp\tools\pwsh\pwsh.exe
  echo   or install PowerShell 7 and put pwsh.exe on PATH.
  echo.
  echo   Windows PowerShell 5.1 is not supported: cjpm 1.0.5 exits with
  echo   0xC0000005 when launched by powershell.exe 5.1.
  exit /b 2
)
"%PWSH%" -NoProfile -File "%HERE%verify.ps1" %*
exit /b %ERRORLEVEL%
