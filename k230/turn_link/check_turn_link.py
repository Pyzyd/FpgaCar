"""Drive the Ti60 bench RTL with a trace from the deployed MicroPython sender."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "k230/turn_verify"
BENCH = ROOT / "k230/turn_link/ti60/TurnLinkBench.v"


def sender_trace():
    ms = 0
    writes = []
    blocked = set()

    class FPIOA:
        GPIO42, GPIO43, GPIO34, GPIO35 = 42, 43, 34, 35
        RESV = -1

        def get_pin_func(self, pin):
            return 999 if pin in blocked else pin

        def set_function(self, pin, func):
            assert pin == func

    class Pin:
        OUT = 1

        def __init__(self, gpio, mode, value):
            self.gpio = gpio
            self.value(value)

        def value(self, value):
            writes.append((ms, self.gpio, value))

    def sleep(delay):
        nonlocal ms
        ms += delay

    with patch.dict(sys.modules, {"machine": SimpleNamespace(FPIOA=FPIOA, Pin=Pin)}):
        spec = importlib.util.spec_from_file_location("sender", APP / "turn_gpio.py")
        gpio = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gpio)
    gpio.time = SimpleNamespace(sleep_ms=sleep, ticks_ms=lambda: ms, ticks_diff=lambda a, b: a - b)
    blocked.add(34)
    try:
        gpio.TurnLink()
    except RuntimeError as exc:
        assert "GPIO34" in str(exc) and not writes
    else:
        raise AssertionError("pin mux conflict accepted")
    blocked.clear()
    link = gpio.TurnLink()
    link.poll()  # First heartbeat immediately after initialization.
    sleep(100)
    assert link.send_turn("left")
    end_left = ms
    sleep(499)
    link.poll()
    assert link.sent_heartbeats == 1
    sleep(1)
    link.poll()
    sleep(100)
    assert link.send_turn("right")
    assert link.sent_turns == 2 and link.sent_heartbeats == 2
    link.close()
    symbols, data = [], {42: 0, 43: 0, 34: 0}
    for _, pin, value in writes:
        if pin in data:
            data[pin] = value
        elif value:
            symbols.append(data[42] + 2 * data[43] + 4 * data[34])
    assert symbols == ([0, 7, 0, 1, 0] * 2 + [0, 2, 0, 1, 0] * 2 +
                       [0, 7, 0, 1, 0] * 2 + [0, 2, 0, 2, 0] * 2)
    return writes, end_left


def replay(compiler, trace, end_left):
    compiler = compiler.resolve()
    source = ["""`timescale 1ns/1ns
module replay;
reg clk=0; always #5000 clk=~clk;
reg reset_n=0, stb=0; reg [2:0] data=0;
wire [5:0] led;
wire [6:0] motor;
TurnLinkBench #(.CLK_FREQ(100000)) dut(clk, reset_n, data, stb, led,
    motor[6],motor[5],motor[4],motor[3],motor[2],motor[1],motor[0]);
integer events=0;
always @(posedge clk) if (dut.ready && dut.turn != 0) events=events+1;
always @(posedge clk) if (motor !== 7'd0) $fatal(1,"Motor outputs not off");
initial begin
#100000; reset_n=1; #100000;
"""]
    previous = 0
    checked_left = False
    for t, pin, value in trace:
        if t >= end_left and not checked_left:
            source.append("#%d;" % ((end_left - previous) * 1000000))
            source.append("if (led[4:0] !== 5'b01100 || events != 1) $fatal(1,\"Left LED/count mismatch\");")
            previous, checked_left = end_left, True
        name = "stb" if pin == 35 else "data[%d]" % (42, 43, 34).index(pin)
        source.append("#%d; %s=%d;" % ((t - previous) * 1000000, name, value))
        previous = t
    source.append("""#50000;
if (led[4:0] !== 5'b11010 || events != 2) $fatal(1,"Right LED/count mismatch");
#2100000000;
if (led[0] !== 1'b1 || led[2] !== 1'b0 || events != 2) $fatal(1,"Timeout or last direction mismatch");
$display("PASS: K230 sender -> existing Ti60 RTL -> LEDs, exactly two direction events, timeout, motor outputs off");
$finish;
end endmodule
""")
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="turn_link_", dir=scratch) as p:
        p = Path(p)
        tb = p / "trace.v"
        sim = p / "trace.vvp"
        tb.write_text("\n".join(source), encoding="ascii")
        env = dict(os.environ, PATH=str(compiler) + os.pathsep + os.environ.get("PATH", ""))
        def exe(name):
            return str(compiler / (name + (".exe" if os.name == "nt" else "")))
        subprocess.run([exe("iverilog"), "-g2012", "-s", "replay", "-o", str(sim.relative_to(ROOT)),
                        str(BENCH.relative_to(ROOT)), "src/k230_link.v", str(tb.relative_to(ROOT))],
                       cwd=ROOT, env=env, check=True)
        subprocess.run([exe("vvp"), str(sim.relative_to(ROOT))], cwd=ROOT, env=env, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog-dir", type=Path, required=True)
    args = parser.parse_args()
    replay(args.iverilog_dir, *sender_trace())
