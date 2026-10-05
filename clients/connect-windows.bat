@echo off
rem Double-click to connect this PC to the home server.
rem Optional: connect-windows.bat -Domain home.example.org -InstallCert
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-windows.ps1" %*
echo.
pause
