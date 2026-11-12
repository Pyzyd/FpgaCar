"""JTAG downloader workaround for the FT232H set_up_urls IndexError.

Reproduces ftdi_program.py's __main__ flow, but pads the FTDI URL list to 4
entries so that bus index "B" (=1) does not fall off the end on single-interface
FT232H parts.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, r"C:\Efinity\2026.1\pgm\bin")

import efx_pgm.ftdi_program as fp
from efx_pgm.efx_hw_common.device import EfxFTDIDevice
from efx_pgm.util.gen_util import set_efinity_user_dir_env


def padded_set_up_urls(ftdi, connections, url, aurl):
    usb_targets = [t for t in connections if isinstance(t, EfxFTDIDevice)]
    if url:
        url_list = None
        for target in usb_targets:
            if url in target.URLS:
                url_list = list(target.URLS)
                break
        if url_list is None:
            raise ValueError("Specified FTDI URL could not be matched to any connected USB targets")
    else:
        url_list = list(usb_targets[0].URLS)

    print("INFO: usb_targets=%d, raw url_list=%r" % (len(usb_targets), url_list))
    # pad to 4 so bus indices A/B/C/D (0..3) are always valid
    while len(url_list) < 4:
        url_list.append(url_list[0])
    print("INFO: padded url_list=%r" % (url_list,))

    bus_to_url_idx = {"A": 0, "B": 1, "C": 2, "D": 3}
    jtag_url_idx = bus_to_url_idx[ftdi.get_jtag_bus_from_pinout()]
    spi_url_idx = bus_to_url_idx[ftdi.get_spi_bus_from_pinout()]
    if ftdi.mode in fp.JTAG_PROG_MODES:
        jtag_url = url if url else url_list[jtag_url_idx]
        spi_url = aurl if aurl else url_list[spi_url_idx]
    else:
        jtag_url = aurl if aurl else url_list[jtag_url_idx]
        spi_url = url if url else url_list[spi_url_idx]

    ftdi_urls = [None, None, None, None]
    ftdi_urls[jtag_url_idx] = jtag_url
    ftdi_urls[spi_url_idx] = spi_url
    return ftdi_urls


fp.set_up_urls = padded_set_up_urls


def main():
    set_efinity_user_dir_env()
    legacy_mode, _, creset_before_jtag_config = fp.apply_hwtools_config()
    args = fp.parse_cmdline()

    from efx_pgm.usb_resolver import UsbResolver
    usb_resolver = UsbResolver()
    for warning in usb_resolver.get_board_profile_warnings():
        print(warning)

    usb_connects = usb_resolver.get_usb_connections()
    if not usb_connects:
        print("ERROR: No USB target detected, aborting!")
        return 1
    if len(usb_connects) > 1 and args.url == "":
        print("ERROR: More than one USB target detected, FTDI URL must be specified.")
        return 1

    if args.board_profile:
        args.pinout = fp.set_up_pinout_from_profile(args.board_profile)
    args.address, args.num_bytes = fp.validate_address_and_bytes(args.address, args.num_bytes)
    args.urls = []

    prog = fp.FtdiProgram(args)
    try:
        prog.urls = padded_set_up_urls(prog, usb_connects, args.url, args.aurl)
    except ValueError as exc:
        print("ERROR: %s" % exc)
        return 1
    prog.creset_before_jtag_config = creset_before_jtag_config
    prog.verify_method = args.verify_method

    prog_modes = ["passive", "active", "jtag", "jtag_chain", "jtag_bridge", "jtag_bridge_x8"]
    if legacy_mode is False and args.mode in prog_modes:
        if not fp.check_mode_file_compatibility(args.mode, args.input_file):
            return 1

    prog.jtag_session_url = fp.configure_jtag_session(prog=prog)
    print("INFO: jtag session ready: %s" % prog.jtag_session_url)

    import os
    if os.environ.get("JTAG_DRY_RUN") == "1":
        print("DRY RUN: stopped before programming (JTAG_DRY_RUN=1)")
        try:
            from efx_dbg.jtag import JtagManager
            JtagManager().unconfig_jtag(JtagManager().get_configured_jtag_by_url(prog.jtag_session_url))
        except Exception:
            pass
        return 0

    try:
        if prog.mode == "passive":
            prog.spi_direct_program()
        elif prog.mode == "active":
            prog.spi_flash_program(flash_address=args.address, erase_entire_flash=False)
        elif prog.mode == "jtag":
            prog.jtag_program()
        elif prog.mode == "jtag_chain":
            prog.jtag_program(chain=True)
        elif prog.mode == "erase_flash":
            prog.spi_erase_flash(start=args.address, length=args.num_bytes)
        elif prog.mode == "read_flash":
            prog.spi_read_flash(start_address=args.address,
                                read_length=args.num_bytes,
                                output_file=args.output_file)
        elif prog.mode == "jtag_bridge":
            prog.jtag2spi()
        elif prog.mode == "jtag_bridge_x8":
            prog.jtag2spi_x8()
        else:
            print("unsupported mode in this wrapper: %s" % prog.mode)
            return 1
    except (fp.FtdiProgramError, ValueError, AssertionError) as exc:
        print("ERROR: problem occurred during {} programming: {}".format(args.mode, exc))
        import traceback
        traceback.print_exc()
        return 1
    finally:
        try:
            from efx_dbg.jtag import JtagManager
            JtagManager().unconfig_jtag(JtagManager().get_configured_jtag_by_url(prog.jtag_session_url))
        except Exception:
            pass
    print("PROGRAMMING DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
