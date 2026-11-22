"""Generate a standalone Efinity project for the MC130 wheel bench."""

import argparse
from pathlib import Path
from shutil import copyfile
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROJECT = "http://www.efinixinc.com/enf_proj"
INTERFACE = "http://www.efinixinc.com/peri_design_db"
NAME = "Mc130WheelBench"
PINS = {
    "clk", "key_start_n", "key_stop_n", "enc_la", "enc_lb", "enc_ra", "enc_rb",
    "motor_stby", "ml_pwm", "mr_pwm", "ml_in1", "ml_in2", "mr_in1", "mr_in2", "uart_tx",
} | {f"led[{n}]" for n in range(6)}
SOURCES = [HERE / (NAME + ".v"), HERE / "WheelJog.v"] + [
    ROOT / "src" / name for name in
    ("pwm_gen.v", "encoder_dec.v", "speed_meter.v", "uart_report.v", "uart_tx.v")
]


def write_xml(tree, destination):
    ET.indent(tree, space="    ")
    tree.write(destination, encoding="utf-8", xml_declaration=True)


def generate(destination):
    ET.register_namespace("efx", PROJECT)
    ET.register_namespace("efxpt", INTERFACE)
    ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
    project_ns = "{" + PROJECT + "}"
    interface_ns = "{" + INTERFACE + "}"

    project = ET.parse(ROOT / "FpgaCar.xml")
    project.getroot().set("name", NAME)
    design = project.find(project_ns + "design_info")
    design.find(project_ns + "top_module").set("name", NAME)
    for entry in design.findall(project_ns + "design_file"):
        design.remove(entry)
    for i, source in enumerate(SOURCES, start=1):
        design.insert(i, ET.Element(project_ns + "design_file", name=source.name,
                                    version="default", library="default"))
    interface = project.find(project_ns + "interface_info")
    for name in ("default_peri_file", "peri_file"):
        interface.find(project_ns + name).set("name", NAME + ".peri.xml")
    constraints = project.find(project_ns + "constraint_info")
    constraints.find(project_ns + "sdc_file").set("name", NAME + ".sdc")

    peri = ET.parse(ROOT / "FpgaCar.peri.xml")
    peri.getroot().set("name", NAME)
    gpio = peri.find(interface_ns + "gpio_info")
    if missing := PINS - {pin.get("name") for pin in gpio}:
        raise ValueError(f"Missing Ti60 interface pins: {sorted(missing)}")
    for pin in list(gpio):
        if pin.get("name") in PINS or pin.tag == interface_ns + "global_unused_config":
            continue
        if pin.tag == interface_ns + "bus" and pin.get("name") == "led":
            continue
        gpio.remove(pin)

    destination.mkdir(parents=True, exist_ok=True)
    write_xml(project, destination / (NAME + ".xml"))
    write_xml(peri, destination / (NAME + ".peri.xml"))
    (destination / (NAME + ".sdc")).write_text(
        "create_clock -period 41.667 [get_ports clk]\n", encoding="ascii")
    for source in SOURCES:
        copyfile(source, destination / source.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
