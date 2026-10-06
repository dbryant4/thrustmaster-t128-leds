@echo off
rem Starts the FS25 to T128 LED bridge. Close this window or press Ctrl+C to clear the LEDs and stop.
cd /d "%~dp0"
fs25_t128_leds.exe %*
echo.
echo The bridge has stopped.
pause
