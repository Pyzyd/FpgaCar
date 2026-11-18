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
rem mode=all  = erase -> write -> read back and compare. This is Efinity's own
rem              default and the ONLY path that actually verifies.
rem --verify_method hostx1 = the PC reads the flash back over JTAG and compares
rem              SHA1 against the source file. The onchipx* methods use the
rem              flash loader's on-chip CRC and are NOT available on every board.
rem
rem Do NOT use --jtag_bridge_mode erase_and_write: ftdi_program.py hard-codes
rem verify_method='none' inside that branch (see the jtag2spi dispatcher), so
rem it prints "PROGRAMMING DONE" with zero verification and exits 0 even if the
rem image is corrupt. Verified 2026-11-18: that path let a bad image reach the
rem flash and the board came up dark after power cycle.
set FLOG=%~dp0..outflowlash_write.log
"%PYEXE%" "%~dp0jtag_program.py" -m jtag_bridge --jtag_bridge_mode all --verify_method hostx1 -b "Generic Board Profile Using FT232H" -u %URL% -x "%JCF%" -n 1 "%IMG%" > "%FLOG%" 2>&1
if errorlevel 1 goto :fail
rem Exit code alone proves nothing: a silent zero-verify path also returns 0.
rem Require the read-back line AND the verify verdict in the log.
findstr /C:"from flash" "%FLOG%" >nul || (echo ERROR: no read-back in log, write NOT verified & goto :fail)
findstr /C:"Flash verify successful" "%FLOG%" >nul || (echo ERROR: Flash verify failed, see "%FLOG%" & goto :fail)
rem A retry path also prints "verify successful"; reject the mismatch marker.
findstr /C:"Flash verify unsuccessful" "%FLOG%" >nul && (echo ERROR: read-back mismatch reported, see "%FLOG%" & goto :fail)
type "%FLOG%"

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
