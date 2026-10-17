@echo off
rem One-time setup: downloads llama.cpp and the gpt-oss-20b model onto this drive.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Setup-USB.ps1" %*
echo.
pause
