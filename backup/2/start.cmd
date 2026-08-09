@echo off
rem Starts the local WinUtil installer server and opens the GUI (no console windows).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server.ps1"
timeout /t 2 /nobreak >nul
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "irm http://localhost:8765/winutil.ps1 | iex"
exit
