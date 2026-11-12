@echo off
rem Read the board's debug UART (CH340 -> COM12, 115200-8-N-1) for N seconds.
rem   mon.bat            -> 5 s on COM12
rem   mon.bat COM12 10   -> 10 s
setlocal
call "%~dp0env.bat"
"%PYEXE%" "%~dp0uart_mon.py" %*
exit /b %ERRORLEVEL%
