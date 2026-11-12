@echo off
rem Efinity 2026.1 environment for the bundled Python 3.11 (needed by efx_pgm / efx_dbg).
rem Without these, ftdi_program.py dies with "No module named 'encodings'" or KeyError EFINITY_USER_DIR.
set EFINITY_HOME=C:/Efinity/2026.1
set EFXPT_HOME=C:/Efinity/2026.1/pt
set EFXPGM_HOME=C:/Efinity/2026.1/pgm
set EFXDBG_HOME=C:/Efinity/2026.1/debugger
set EFXSVF_HOME=C:/Efinity/2026.1/debugger/svf_player
set EFINITY_USER_DIR=C:\Users\16620\.efinity
set EFINITY_USER_DIR_INI=C:/Users/16620/AppData/Local/efinity/user_dir.ini
set PYTHONHOME=C:\Efinity\2026.1\python311
set PYTHONPATH=C:\Efinity\2026.1\debugger\bin;C:\Efinity\2026.1\pgm\bin
set QT_PLUGIN_PATH=C:/Efinity/2026.1/python311
set PYEXE=C:\Efinity\2026.1\python311\bin\python.exe
