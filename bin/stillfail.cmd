@echo off
setlocal
rem still.fail's command on Windows: stillfail.ps1 beside it (Unix's is bin/stillfail). cmd reads a batch file a line
rem at a time as it runs it, and `stillfail uninstall` removes this one with its release: that runs from a copy of
rem this file in the temporary folder, which cmd reads on instead (the release named by STILLFAIL_CMD_HOME).
if /i not "%~1"=="uninstall" goto run
if defined STILLFAIL_CMD_HOME goto run
set "STILLFAIL_CMD_HOME=%~dp0"
set "STILLFAIL_CMD_COPY=%TEMP%\stillfail-uninstall-%RANDOM%.cmd"
copy /y "%~f0" "%STILLFAIL_CMD_COPY%" >nul || goto run
"%STILLFAIL_CMD_COPY%" %*
:run
if not defined STILLFAIL_CMD_HOME set "STILLFAIL_CMD_HOME=%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STILLFAIL_CMD_HOME%stillfail.ps1" %*
exit /b %ERRORLEVEL%
