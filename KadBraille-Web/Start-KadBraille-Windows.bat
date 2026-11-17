@echo off
title Kad Braille - Local Web & PWA Server
echo Starting Kad Braille on http://localhost:8080 ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Port 8080 -OpenBrowser
pause
