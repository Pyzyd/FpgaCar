"""Generate an isolated Efinity project from the project's current fixed pin map."""
import argparse
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
NAME = "TurnLinkBench"
PROJ = "http://www.efinixinc.com/enf_proj"
PERI = "http://www.efinixinc.com/peri_design_db"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
GPIOS = {"clk", "rst_n", "k230_d[0]", "k230_d[1]", "k230_d[2]", "k230_stb",
         "motor_stby", "ml_pwm", "mr_pwm", "ml_in1", "ml_in2", "mr_in1", "mr_in2"}
GPIOS.update("led[%d]" % n for n in range(6))


def write(tree, path):
    ET.indent(tree, space="    ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def generate(dst):
    dst.mkdir(parents=True, exist_ok=True)
    ET.register_namespace("efx", PROJ)
    ET.register_namespace("efxpt", PERI)
    ET.register_namespace("xsi", XSI)
    project = ET.parse(ROOT / "FpgaCar.xml")
    p = "{" + PROJ + "}"
    project.getroot().set("name", NAME)
    design = project.find(p + "design_info")
    design.find(p + "top_module").set("name", NAME)
    for entry in list(design.findall(p + "design_file")):
        design.remove(entry)
    for index, path in enumerate((NAME + ".v", "k230_link.v"), 1):
        design.insert(index, ET.Element(p + "design_file", name=path, version="default", library="default"))
    for entry in project.find(p + "interface_info"):
        if entry.tag in (p + "default_peri_file", p + "peri_file"):
            entry.set("name", NAME + ".peri.xml")
    project.find(p + "constraint_info/" + p + "sdc_file").set("name", NAME + ".sdc")
    write(project, dst / (NAME + ".xml"))

    peri = ET.parse(ROOT / "FpgaCar.peri.xml")
    peri.getroot().set("name", NAME)
    q = "{" + PERI + "}"
    gpio_info = peri.find(q + "gpio_info")
    for gpio in list(gpio_info):
        if gpio.tag == q + "comp_gpio" and gpio.get("name") == "key_start_n":
            # The standalone link bench still uses K1 as its logic reset.
            for node in gpio.iter():
                for key, value in node.attrib.items():
                    if value.startswith("key_start_n"):
                        node.set(key, value.replace("key_start_n", "rst_n", 1))
        retained = (gpio.tag == q + "global_unused_config" or
                    (gpio.tag == q + "bus" and gpio.get("name") in {"led", "k230_d"}) or
                    (gpio.tag == q + "comp_gpio" and gpio.get("name") in GPIOS))
        if not retained:
            gpio_info.remove(gpio)
    assert {g.get("name") for g in gpio_info.findall(q + "comp_gpio")} == GPIOS
    write(peri, dst / (NAME + ".peri.xml"))
    (dst / (NAME + ".sdc")).write_text("create_clock -period 41.667 [get_ports clk]\n", encoding="ascii")
    shutil.copyfile(HERE / (NAME + ".v"), dst / (NAME + ".v"))
    shutil.copyfile(ROOT / "src/k230_link.v", dst / "k230_link.v")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
