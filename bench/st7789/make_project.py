"""Generate a standalone ST7789 Efinity project using the Ti60 board template."""

import argparse
from copy import deepcopy
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "St7789Bench"
PROJECT = "http://www.efinixinc.com/enf_proj"
INTERFACE = "http://www.efinixinc.com/peri_design_db"
BASE_PINS = {"clk", "rst_n", "motor_stby", "ml_pwm", "mr_pwm", "ml_in1",
             "ml_in2", "mr_in1", "mr_in2"} | {f"led[{n}]" for n in range(6)}
LCD_PINS = {
    "lcd_sclk": "GPIOL_N_17",  # P4 35
    "lcd_mosi": "GPIOL_P_17",  # P4 36
    "lcd_dc": "GPIOL_N_18",    # P4 37
    "lcd_rst_n": "GPIOL_P_18", # P4 38
    "lcd_cs_n": "GPIOT_P_11",  # P4 40
}


def write_xml(tree, path):
    ET.indent(tree, space="    ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def generate(destination):
    destination.mkdir(parents=True, exist_ok=True)
    ET.register_namespace("efx", PROJECT)
    ET.register_namespace("efxpt", INTERFACE)
    ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
    p = "{" + PROJECT + "}"
    q = "{" + INTERFACE + "}"

    project = ET.parse(ROOT / "FpgaCar.xml")
    project.getroot().set("name", NAME)
    design = project.find(p + "design_info")
    design.find(p + "top_module").set("name", NAME)
    for entry in design.findall(p + "design_file"):
        design.remove(entry)
    design.insert(1, ET.Element(p + "design_file", name=NAME + ".v",
                               version="default", library="default"))
    interface = project.find(p + "interface_info")
    for kind in ("default_peri_file", "peri_file"):
        interface.find(p + kind).set("name", NAME + ".peri.xml")
    project.find(f"{p}constraint_info/{p}sdc_file").set("name", NAME + ".sdc")
    write_xml(project, destination / (NAME + ".xml"))

    peri = ET.parse(ROOT / "FpgaCar.peri.xml")
    peri.getroot().set("name", NAME)
    gpio = peri.find(q + "gpio_info")
    existing = {pin.get("name"): pin for pin in gpio.findall(q + "comp_gpio")}
    if missing := BASE_PINS.difference(existing):
        raise ValueError(f"Missing Ti60 board pins: {sorted(missing)}")
    for pin in list(gpio):
        if pin.get("name") in BASE_PINS or pin.tag == q + "global_unused_config":
            continue
        if pin.tag == q + "bus" and pin.get("name") == "led":
            continue
        gpio.remove(pin)

    # LCD signals use the same 1.8 V FPGA-side settings as other P4 outputs.
    # The carrier translates to 3.3 V on the expansion header.
    unused_index = list(gpio).index(gpio.find(q + "global_unused_config"))
    for name, ball in LCD_PINS.items():
        if any(pin.get("gpio_def") == ball for pin in existing.values()):
            raise ValueError(f"Reserved LCD pin {ball} is already assigned")
        pin = deepcopy(existing["ml_pwm"])
        pin.set("name", name)
        pin.set("gpio_def", ball)
        pin.find(q + "output_config").set("name", name)
        gpio.insert(unused_index, pin)
        unused_index += 1
    write_xml(peri, destination / (NAME + ".peri.xml"))

    (destination / (NAME + ".sdc")).write_text(
        "create_clock -period 41.667 [get_ports clk]\n", encoding="ascii"
    )
    shutil.copyfile(HERE / (NAME + ".v"), destination / (NAME + ".v"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
