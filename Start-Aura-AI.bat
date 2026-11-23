@echo off
setlocal
title Aura Voice Studio - AI Speech Server
cd /d "%~dp0backend"

where python >nul 2>&1
if errorlevel 1 (
  echo Python was not found.
  echo Install Python 3.11 or newer, enable "Add Python to PATH", then run this file again.
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo Creating the Aura Voice backend environment...
  python -m venv .venv
  if errorlevel 1 (
    echo Could not create the Python environment.
    pause
    exit /b 1
  )
)

echo Installing or updating Aura Voice AI dependencies...
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
  echo Dependency installation failed. Check your internet connection and Python installation.
  pause
  exit /b 1
)

echo.
echo Aura Voice AI is starting at http://127.0.0.1:8000
echo Keep this window open while using AI Voice Studio.
echo Press Ctrl+C here to stop the AI server.
echo.
".venv\Scripts\python.exe" -m uvicorn app.main:app --host 127.0.0.1 --port 8000
if errorlevel 1 (
  echo Aura Voice AI stopped with an error.
  pause
)
endlocal
