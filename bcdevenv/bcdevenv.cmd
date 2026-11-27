@echo off
REM ---------------------------------------------------------------------------
REM  bcdevenv - PATH shim for the Business Central dev-container CLI (.NET 10).
REM  Runs the prebuilt exe if present; otherwise builds/runs via 'dotnet run'.
REM ---------------------------------------------------------------------------
setlocal
set "BCDEVENV_DIR=%~dp0"
set "EXE=%BCDEVENV_DIR%src\BcDevEnv.Cli\bin\Release\net10.0\win-x64\bcdevenv.exe"

if exist "%EXE%" (
    "%EXE%" %*
) else (
    dotnet run --project "%BCDEVENV_DIR%src\BcDevEnv.Cli\BcDevEnv.Cli.csproj" -c Release -- %*
)
exit /b %ERRORLEVEL%
