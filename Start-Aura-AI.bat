@echo off
setlocal
title Aura Voice Studio - Local AI Speech Server
cd /d "%~dp0"

if not exist "backend_runtime\aura-ai-server.exe" (
  echo The bundled Aura Voice AI server was not found.
  echo Reinstall Aura Voice Studio using Aura-Voice-Studio-Setup-x64.exe.
  pause
  exit /b 1
)

echo Starting the bundled Aura Voice AI server...
echo The AI Voice Studio app normally starts this server automatically.
echo Keep this window open while using AI Voice Studio.
echo Service: http://127.0.0.1:8000
echo.
pushd "backend_runtime"
"aura-ai-server.exe"
popd
if errorlevel 1 (
  echo Aura Voice AI stopped with an error.
  pause
)
endlocal
