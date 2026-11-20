"""Generate a standalone LCD or camera snapshot project from the Ti60 board template."""

import argparse
from copy import deepcopy
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROJECT = "http://www.efinixinc.com/enf_proj"
INTERFACE = "http://www.efinixinc.com/peri_design_db"
# 复位在 RTL 里叫 rst_n；底板随版本不同，这个信号可能落在 key_start_n /
# key_stop_n（K1/K2 按键版）或旧的 rst_n 上。生成时挑当前 peri.xml 里存在的那个，
# 再在生成的约束里统一改名回 rst_n —— RTL 端口名必须与约束块名一致。
RESET_CANDIDATES = ("key_start_n", "key_stop_n", "rst_n")
BASE_PINS = {"clk", "motor_stby", "ml_pwm", "mr_pwm", "ml_in1",
             "ml_in2", "mr_in1", "mr_in2"} | {f"led[{n}]" for n in range(6)}
CAMERA_PINS = {"cmos_pclk", "cmos_href", "cmos_vsync", "cmos_xclk", "cmos_sclk",
               "cmos_sdat", "cmos_ctl1", "cmos_rst_n", "cmos_pwdn"} | {
                   f"cmos_data[{n}]" for n in range(8)
               }
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


def generate(destination, camera=False, snapshot=False):
    destination.mkdir(parents=True, exist_ok=True)
    pins = BASE_PINS
    if snapshot:
        name = "Ov5640UartBench"
        files = [HERE / (name + ".v"), HERE / "ov5640_uart_snapshot.v",
                 ROOT / "src" / "uart_tx.v"]
        pins = pins | {"uart_rx", "uart_tx"}
    else:
        name = "Ov5640LcdBench" if camera else "St7789Bench"
        files = [HERE / "St7789Bench.v"]
        if camera:
            files.append(HERE / (name + ".v"))
    buses = {"led"}
    sdc = "create_clock -period 41.667 [get_ports clk]\n"
    if camera or snapshot:
        pins = pins | CAMERA_PINS
        buses.add("cmos_data")
        files.append(HERE / "ov5640_preview_frame.v")
        files.extend(ROOT / "src" / source for source in
                     ("cam_probe.v", "cam_sccb_cfg.v", "i2c_timing_ctrl_16bit.v",
                      "I2C_OV5640_1280720_Config.v"))
        sdc += ("create_clock -period 20.000 [get_ports cmos_pclk]\n"
                "set_clock_groups -asynchronous -group [get_clocks clk] "
                "-group [get_clocks cmos_pclk]\n")

    ET.register_namespace("efx", PROJECT)
    ET.register_namespace("efxpt", INTERFACE)
    ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
    p = "{" + PROJECT + "}"
    q = "{" + INTERFACE + "}"

    project = ET.parse(ROOT / "FpgaCar.xml")
    project.getroot().set("name", name)
    design = project.find(p + "design_info")
    design.find(p + "top_module").set("name", name)
    for entry in design.findall(p + "design_file"):
        design.remove(entry)
    for index, source in enumerate(files, 1):
        design.insert(index, ET.Element(p + "design_file", name=source.name,
                                        version="default", library="default"))
    interface = project.find(p + "interface_info")
    for kind in ("default_peri_file", "peri_file"):
        interface.find(p + kind).set("name", name + ".peri.xml")
    project.find(f"{p}constraint_info/{p}sdc_file").set("name", name + ".sdc")
    write_xml(project, destination / (name + ".xml"))

    peri = ET.parse(ROOT / "FpgaCar.peri.xml")
    peri.getroot().set("name", name)
    gpio = peri.find(q + "gpio_info")
    existing = {pin.get("name"): pin for pin in gpio.findall(q + "comp_gpio")}

    # 复位源：底板随版本不同，K1/K2 按键版没有 rst_n 这个约束块。
    # 挑一个存在的，再在下面把块名改回 rst_n 与 RTL 端口对齐。
    reset_src = next((n for n in RESET_CANDIDATES if n in existing), None)
    if reset_src is None:
        raise ValueError(
            f"No reset pin among {RESET_CANDIDATES}; available: {sorted(existing)}")
    pins = pins | {reset_src}
    if missing := pins.difference(existing):
        raise ValueError(f"Missing Ti60 board pins: {sorted(missing)}")
    for pin in list(gpio):
        if pin.get("name") in pins or pin.tag == q + "global_unused_config":
            continue
        if pin.tag == q + "bus" and pin.get("name") in buses:
            continue
        gpio.remove(pin)

    # LCD signals use the same 1.8 V FPGA-side settings as other P4 outputs.
    # The carrier translates to 3.3 V on the expansion header.
    unused_index = list(gpio).index(gpio.find(q + "global_unused_config"))
    for signal, ball in (() if snapshot else LCD_PINS.items()):
        if any(pin.get("gpio_def") == ball for pin in existing.values()):
            raise ValueError(f"Reserved LCD pin {ball} is already assigned")
        pin = deepcopy(existing["ml_pwm"])
        pin.set("name", signal)
        pin.set("gpio_def", ball)
        pin.find(q + "output_config").set("name", signal)
        gpio.insert(unused_index, pin)
        unused_index += 1
    # 把复位块名统一改回 rst_n，与 bench 顶层端口一致。
    if reset_src != "rst_n":
        blk = existing[reset_src]
        blk.set("name", "rst_n")
        cfg = blk.find(q + "input_config")
        if cfg is not None:
            cfg.set("name", "rst_n")

    write_xml(peri, destination / (name + ".peri.xml"))

    (destination / (name + ".sdc")).write_text(sdc, encoding="ascii")
    for source in files:
        shutil.copyfile(source, destination / source.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--camera", action="store_true", help="include OV5640 grayscale preview")
    mode.add_argument("--snapshot", action="store_true", help="take OV5640 photos over CH340N UART")
    args = parser.parse_args()
    generate(args.output, args.camera, args.snapshot)
