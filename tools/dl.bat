@echo off
rem ---------------------------------------------------------------------------
rem Download outflow\FpgaCar.bit into the Ti60 over JTAG.
rem   dl.bat                 -> passive JTAG config (volatile, lost on power-off)
rem   dl.bat other.bit       -> any other bitstream
rem Workaround for the Efinity 2026.1 bug: ftdi_program.py set_up_urls() indexes
rem url_list[1] for the JTAG bus ("B" = BDBUS), but an FT232H exposes a single
rem interface, so URLS has length 1 -> IndexError. tools\jtag_program.py pads the
rem list to 4 entries.
rem ---------------------------------------------------------------------------
setlocal
call "%~dp0env.bat"

set URL=ftdi://0x0403:0x6014:0:ff/1
set STREAM=%~dp0..\outflow\FpgaCar.bit
if not "%~1"=="" set STREAM=%~1

if not exist "%STREAM%" (
        echo ERROR: bitstream not found: %STREAM%
        exit /b 1
)
if not exist "%~dp0..\_jtag.jcf" (
        echo ERROR: JTAG chain file missing, run: jtag_chain_detect.py -f %URL% -o ..\_jtag.jcf
        exit /b 1
)

"%PYEXE%" "%~dp0jtag_program.py" -m jtag -b "Generic Board Profile Using FT232H" -u %URL% -x "%~dp0..\_jtag.jcf" -n 1 "%STREAM%"
exit /b %ERRORLEVEL%
