@echo off
REM Double-click me. Runs setup-windows.ps1 (it asks for Administrator rights itself).
REM Extra args are passed through, e.g. setup-windows.bat -NoModels
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" %*
pause
