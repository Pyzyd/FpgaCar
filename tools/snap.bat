@echo off
rem Grab the 40x30 thumbnail (frame_snap.v) into data\_frame.bmp / data\_frame.csv
rem   snap.bat                 -> COM12
rem   snap.bat COM12 _red      -> custom port and output prefix
rem Board sends 3 frames right after reset + 1.5 s, so press the reset button
rem (or re-download the bitstream) while this is running.
setlocal
call "%~dp0env.bat"
"%PYEXE%" "%~dp0grab_frame.py" %*
exit /b %ERRORLEVEL%
