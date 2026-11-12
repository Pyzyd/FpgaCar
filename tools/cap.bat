@echo off
rem Paired two-line capture.  cap.bat [PORT] [SECONDS] [OUT.csv]
setlocal
call "%~dp0env.bat"
"%PYEXE%" "%~dp0cap.py" %*
exit /b %ERRORLEVEL%
