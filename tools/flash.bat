@echo off
rem ---------------------------------------------------------------------------
rem Persist outflow\FpgaCar.hex into the on-board configuration SPI flash.
rem   flash.bat              -> flash outflow\FpgaCar.hex, then re-arm the app
rem   flash.bat other.hex    -> any other hex image
rem
rem Why three steps:
rem   1. This board's FT232H is wired to the JTAG pins only, so "SPI Active"
rem      (direct) programming cannot reach the flash: CCK/CS are not on the
rem      FTDI header. Verified: "ERROR: Unknown error trying to read flash".
rem   2. The flash is therefore reached through the JTAG->SPI bridge, which is
rem      itself a bitstream that has to be running in the FPGA first. Efinity
rem      ships it prebuilt at pgm\fli\titanium\u10660A79.bit.
rem      Without it: "Unsupported JTAG Bridge version: 255.255".
rem   3. After the flash write the FPGA holds the bridge design, so the real
rem      application bitstream is loaded back over JTAG to leave the board
rem      running the car logic.
rem ---------------------------------------------------------------------------
setlocal
call "%~dp0env.bat"

set URL=ftdi://0x0403:0x6014:0:ff/1
set JCF=%~dp0..\_jtag.jcf
set BRIDGE=C:\Efinity\2026.1\pgm\fli\titanium\u10660A79.bit
set APP=%~dp0..\outflow\FpgaCar.bit
set IMG=%~dp0..\outflow\FpgaCar.hex
if not "%~1"=="" set IMG=%~1

if not exist "%IMG%" (
        echo ERROR: hex image not found: %IMG%
        exit /b 1
)
if not exist "%JCF%" (
        echo ERROR: JTAG chain file missing, run: jtag_chain_detect.py -f %URL% -o ..\_jtag.jcf
        exit /b 1
)

echo [1/3] Loading JTAG-to-SPI bridge image ...
"%PYEXE%" "%~dp0jtag_program.py" -m jtag -b "Generic Board Profile Using FT232H" -u %URL% -x "%JCF%" -n 1 "%BRIDGE%"
if errorlevel 1 goto :fail

echo [2/3] Writing %IMG% into SPI flash ...
"%PYEXE%" "%~dp0jtag_program.py" -m jtag_bridge -b "Generic Board Profile Using FT232H" -u %URL% -x "%JCF%" -n 1 "%IMG%"
if errorlevel 1 goto :fail

echo [3/3] Restoring application bitstream ...
if exist "%APP%" (
        "%PYEXE%" "%~dp0jtag_program.py" -m jtag -b "Generic Board Profile Using FT232H" -u %URL% -x "%JCF%" -n 1 "%APP%"
        if errorlevel 1 goto :fail
) else (
        echo WARNING: %APP% not found, board is left running the bridge image.
        echo          Re-run tools\dl.bat once a bitstream exists.
)

echo FLASH DONE
exit /b 0

:fail
echo FLASH FAILED
exit /b 1
