"""Generate the standalone 720p snapshot project using the SZOVS Ti60 DDR3 demo."""

import argparse
from copy import deepcopy
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

from make_project import BASE_PINS, CAMERA_PINS, HERE, INTERFACE, PROJECT, ROOT, write_xml


NAME = "Ov5640DdrSnapshot"
DDR_BUSES = {"addr", "ba", "dm", "dq", "dqs", "dqs_n"}
DDR_PINS = {"clk_24m", "cas", "cke", "clk_n", "clk_p", "cs", "odt", "ras",
            "reset", "verf0", "vref1", "we"}
APP_PINS = (BASE_PINS - {"clk"}) | CAMERA_PINS | {"key_start_n", "uart_rx", "uart_tx"}
DDR_CLOCKS = {"tdqss_clk", "core_clk", "tac_clk", "twd_clk", "clk_sys"}
SOURCES = [
    HERE / source for source in
    (NAME + ".v", "ov5640_photo_capture.v", "ov5640_photo_fifo.v",
     "ov5640_photo_store.v", "ov5640_uart_snapshot.v")
] + [
    ROOT / "src" / source for source in
    ("cam_probe.v", "cam_sccb_cfg.v", "i2c_timing_ctrl_16bit.v",
     "I2C_OV5640_1280720_Config.v", "uart_tx.v")
]


def generate(destination, vendor):
    ET.register_namespace("efx", PROJECT)
    ET.register_namespace("efxpt", INTERFACE)
    ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
    p = "{" + PROJECT + "}"
    q = "{" + INTERFACE + "}"
    project = ET.parse(ROOT / "FpgaCar.xml")
    peri = ET.parse(vendor / "Ti60_Demo.peri.xml")
    app_peri = ET.parse(ROOT / "FpgaCar.peri.xml")
    ip = vendor / "ip" / "DdrCtrl"
    ddr_sources = [ip / f for f in ("DdrCtrl.v", "ddr3_controller.vh",
                                    "ddr3_device_ID.vh", "ddr3_controller.bin")]
    for source in ddr_sources:
        if not source.is_file():
            raise FileNotFoundError(source)

    gpio = peri.find(q + "gpio_info")
    kept_pins = set()
    for entry in list(gpio):
        name = entry.get("name", "")
        bus = name.split("[", 1)[0]
        if name in DDR_PINS or bus in DDR_BUSES:
            kept_pins.add(name)
        elif entry.tag != q + "global_unused_config":
            gpio.remove(entry)
    if missing := DDR_PINS - kept_pins:
        raise ValueError(f"DDR pin definitions missing from vendor project: {sorted(missing)}")
    used_balls = {pin.get("gpio_def") for pin in gpio.findall(q + "comp_gpio")}
    unused_gpio = gpio.find(q + "global_unused_config")
    new_pins = set()
    for entry in app_peri.find(q + "gpio_info"):
        name = entry.get("name")
        if entry.tag == q + "bus" and name in {"led", "cmos_data"}:
            gpio.append(deepcopy(entry))
        elif name in APP_PINS:
            ball = entry.get("gpio_def")
            if ball in used_balls:
                raise ValueError(f"DDR pin collision at {name} ({ball})")
            new_pins.add(name)
            pin = deepcopy(entry)
            if name == "cmos_xclk":
                pin.find(q + "output_config").set("clock_name", "clk_24m")
            gpio.insert(list(gpio).index(unused_gpio), pin)
    if missing := APP_PINS - new_pins:
        raise ValueError(f"Bench pin definitions missing: {sorted(missing)}")

    pll = peri.find(q + "pll_info")
    for entry in list(pll):
        if entry.get("name") not in {"sys_pll", "ddr_pll"}:
            pll.remove(entry)
        else:
            for clock in entry.findall(q + "comp_output_clock"):
                if clock.get("name") not in DDR_CLOCKS:
                    entry.remove(clock)
    for module in ("lvds_info", "mipi_dphy_info"):
        group = peri.find(q + module)
        for entry in list(group):
            group.remove(entry)

    project.getroot().set("name", NAME)
    peri.getroot().set("name", NAME)
    design = project.find(p + "design_info")
    design.find(p + "top_module").set("name", NAME)
    for entry in design.findall(p + "design_file"):
        design.remove(entry)
    for index, source in enumerate(SOURCES + [ddr_sources[0]], 1):
        design.insert(index, ET.Element(p + "design_file", name=source.name,
                                         version="default", library="default"))
    interface = project.find(p + "interface_info")
    for kind in ("default_peri_file", "peri_file"):
        interface.find(p + kind).set("name", NAME + ".peri.xml")
    project.find(f"{p}constraint_info/{p}sdc_file").set("name", NAME + ".sdc")

    # Keep the manufacturer's DDR timing constraints in this project. The DVP
    # and DDR clocks exchange data only through the asynchronous FIFO and toggles.
    ddr_constraints = []
    for line in (vendor / "Ti60_Demo.pt.sdc").read_text().splitlines():
        if line.startswith("create_clock ") and line.split()[-1] in DDR_CLOCKS:
            ddr_constraints.append(line.rstrip())
        elif line.startswith(("set_max_delay ", "set_false_path ")):
            clocks = set(re.findall(r"get_clocks\s+\{?(\w+)", line))
            if clocks and clocks <= DDR_CLOCKS:
                ddr_constraints.append(line.rstrip())
    ddr_constraints += [
        "create_clock -period 10.000 [get_ports {cmos_pclk}]",
        "set_clock_groups -asynchronous -group {cmos_pclk} -group {clk_sys core_clk tac_clk twd_clk tdqss_clk}",
    ]
    destination.mkdir(parents=True, exist_ok=True)
    write_xml(project, destination / (NAME + ".xml"))
    write_xml(peri, destination / (NAME + ".peri.xml"))
    (destination / (NAME + ".sdc")).write_text("\n".join(ddr_constraints) + "\n", encoding="ascii")
    for source in SOURCES + ddr_sources:
        shutil.copyfile(source, destination / source.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("vendor_demo", type=Path, help="SZOVS 02-1_Ti60_OV5640_LCD-HDMI_1080P60")
    args = parser.parse_args()
    generate(args.output, args.vendor_demo)
