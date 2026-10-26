@echo off
setlocal
call "%~dp0scripts\run.bat" %*
exit /b %ERRORLEVEL%
