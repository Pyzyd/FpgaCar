"""Check fixed wiring and replay the actual Python sender into Ti60 RTL.

python k230/tools/check_gpio_link.py [--rtl --iverilog-dir <bin directory>]
No hardware is accessed; machine/time are replaced with recording doubles.
"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'k230'))
import config as C


class Fixture:
    def __init__(self):
        self.clock=0
        self.trace=[]
        self.pins={}
        self.mapping={n:n for n in (42,43,34,35)}
        outer=self
        class Mux:
            RESV=-1
            GPIO42=42; GPIO43=43; GPIO34=34; GPIO35=35
            def get_pin_func(self,n): return outer.mapping[n]
            def set_function(self,n,f): outer.mapping[n]=f
        class Pin:
            OUT=1
            def __init__(self,n,mode,value=0):
                self.n,self.v=n,value
                outer.pins[n]=self
                outer.trace.append((outer.clock,n,value))
            def value(self,v=None):
                if v is None: return self.v
                self.v=v
                outer.trace.append((outer.clock,self.n,v))
        machine=types.SimpleNamespace(FPIOA=Mux,Pin=Pin)
        self.context=contextlib.ExitStack()
        self.context.enter_context(patch.dict(sys.modules,{'machine':machine}))
        spec=importlib.util.spec_from_file_location('tested_gpio_link',ROOT/'k230/gpio_link.py')
        self.module=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.module.time=types.SimpleNamespace(ticks_ms=lambda:self.clock,ticks_diff=lambda a,b:a-b,
                                               sleep_ms=self.sleep)
        self.context.enter_context(contextlib.redirect_stdout(io.StringIO()))

    def sleep(self,ms): self.clock+=ms
    def close(self): self.context.close()
    def sender(self): return self.module.GpioLink()
    def symbols(self):
        data={42:0,43:0,34:0}; values=[]
        for _,n,v in self.trace:
            if n in data: data[n]=v
            if n==35 and v: values.append(data[42]+2*data[43]+4*data[34])
        return values


class Checks(unittest.TestCase):
    def setUp(self): self.fx=Fixture()
    def tearDown(self): self.fx.close()

    def test_six_event_codes_and_pulse_widths(self):
        sender=self.fx.sender()
        for code,pair in ((1,(2,1)),(2,(2,2)),(3,(1,1)),(4,(1,3)),(5,(1,4)),(6,(1,2))):
            self.fx.trace=[]
            self.assertTrue(sender.send(code))
            self.assertEqual(self.fx.symbols(),[0,pair[0],0,pair[1],0]*2)
            edges=[(t,v) for t,n,v in self.fx.trace if n==35]
            for rise,fall in zip(edges[::2],edges[1::2]):
                self.assertEqual((rise[1],fall[1]),(1,0))
                self.assertGreaterEqual(fall[0]-rise[0],1)
            self.assertEqual(sender.state,'idle')
        self.assertEqual(sender.sent_frames,6)
        self.assertEqual(self.fx.clock,180)

    def test_heartbeat_and_close(self):
        sender=self.fx.sender()
        sender.poll()
        self.assertEqual(sender.sent_frames,0)
        self.fx.clock=500
        sender.poll()
        self.assertEqual(self.fx.symbols(),[0,7,0,1,0]*2)
        sender.close()
        self.assertTrue(all(p.value()==0 for p in self.fx.pins.values()))
        self.assertEqual(sender.state,'closed')

    def test_does_not_steal_peripheral_mux(self):
        self.fx.mapping[34]=999
        with self.assertRaisesRegex(RuntimeError,'already assigned'): self.fx.sender()
        self.assertEqual(self.fx.pins,{})
        self.assertEqual(self.fx.mapping[34],999)

    def test_readonly_audit_and_fixed_pin_guard(self):
        self.assertEqual(len(self.fx.module.audit_pins(self.fx.module.FPIOA())),4)
        self.assertEqual(self.fx.trace,[])
        with patch.object(C,'DATA_PINS',(42,43,33)):
            with self.assertRaises(ValueError): self.fx.sender()
        self.assertEqual(self.fx.pins,{})

    def test_send_failure_latches_fault(self):
        sender=self.fx.sender()
        def broken(v=None): raise OSError('mock wiring failure')
        sender.data[0].value=broken
        self.assertFalse(sender.send(3))
        self.assertEqual(sender.state,'fault')
        self.assertFalse(sender.send(4))
        self.assertIn('wiring failure',sender.error)

    def test_fixed_contract_matches_ti60_and_lcd_has_no_conflict(self):
        contract=json.loads((ROOT/'docs/k230_gpio_contract.json').read_text(encoding='utf-8'))
        table={}
        for line in (ROOT/'docs/引脚分配表.md').read_text(encoding='utf-8').splitlines():
            if not line.startswith('|'): continue
            cells=[s.strip().replace('**','').replace('`','') for s in line.strip('|').split('|')]
            if len(cells)==6 and cells[0].isdigit(): table[int(cells[0])]=cells
        gpios=[e.attrib for e in ET.parse(ROOT/'FpgaCar.peri.xml').getroot().iter()
               if e.tag.endswith('comp_gpio')]
        by_name={g['name']:g for g in gpios}
        self.assertEqual(tuple(row['k230_gpio'] for row in contract['signals'][:3]),C.DATA_PINS)
        self.assertEqual(contract['signals'][3]['k230_gpio'],C.STROBE_PIN)
        allocated=[g['gpio_def'] for g in gpios]
        for row in contract['signals']:
            gpio=by_name[row['fpga_port']]
            self.assertEqual(gpio['gpio_def'],row['gpio_def'])
            self.assertEqual(gpio['io_standard'],'1.8 V LVCMOS')
            self.assertEqual(gpio['mode'],'input')
            self.assertEqual(allocated.count(row['gpio_def']),1)
        for row in contract['lcd_reserved']:
            self.assertNotIn(row['gpio_def'],allocated)
        for row in contract['signals']+contract['lcd_reserved']:
            cells=table[row['ti60_p4_pin']]
            self.assertEqual(cells[1],'User_IO%d'%row['ti60_user_io'])
            self.assertIn(row['gpio_def'],cells[2])
        p4=[r['ti60_p4_pin'] for r in contract['signals']+contract['lcd_reserved']]
        self.assertEqual(len(p4),len(set(p4)))
        self.assertEqual(by_name['rst_n']['gpio_def'],'GPIOL_P_02')


def rtl_replay(compiler_dir):
    fx=Fixture()
    try:
        sender=fx.sender()
        for code in range(1,7): sender.send(code)
        fx.clock=700
        sender.poll()
        trace=list(fx.trace)
    finally: fx.close()
    script=['`timescale 1ns/1ns','module replay; reg clk=0; always #500 clk=~clk;',
            'reg rst_n=0; reg [2:0] data=0; reg stb=0;',
            'wire [3:0] c; wire [2:0] d; wire [7:0] cmd,err; wire alive;',
            'k230_link #(.CLK_FREQ(1000000)) dut(clk,rst_n,data,stb,c,d,cmd,alive,err);',
            'integer nc=0,nd=0;',
            'always @(posedge clk) if(rst_n) begin',
            'if(c!=0) begin nc=nc+1; if(c!=nc) $fatal(1,"Color order/value mismatch"); end',
            'if(d!=0) begin nd=nd+1; if(d!=nd) $fatal(1,"Direction mismatch"); end end',
            'initial begin #10000; rst_n=1; #10000;']
    previous=0
    for t,n,v in trace:
        script.append('#%d; %s=%d;' % ((t-previous)*1000000,
                      'stb' if n==35 else 'data[%d]'%(42,43,34).index(n),v))
        previous=t
    script.extend(['#2000000; if(nc!=4 || nd!=2 || err!=0 || !alive) $fatal(1,"Replay failed");',
                   '$display("PASS: actual K230 Python sender -> Ti60 RTL, four colors/two directions/heartbeat");',
                   '$finish; end endmodule'])
    scratch=ROOT/'.scratch'
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='gpio_replay_',dir=scratch) as tmp:
        tmp=pathlib.Path(tmp)
        bench=tmp/'replay.v'; bench.write_text('\n'.join(script),encoding='ascii')
        out=tmp/'replay.vvp'
        env=dict(os.environ)
        env['PATH']=str(pathlib.Path(compiler_dir))+os.pathsep+env.get('PATH','')
        for args in ([str(pathlib.Path(compiler_dir)/'iverilog.exe'),'-g2012','-s','replay','-o',str(out),
                      str(ROOT/'src/k230_link.v'),str(bench)],
                     [str(pathlib.Path(compiler_dir)/'vvp.exe'),str(out)]):
            result=subprocess.run(args,capture_output=True,text=True,timeout=45,env=env)
            print(result.stdout,end='')
            if result.returncode: raise RuntimeError('%s exit %s: %s'%(args[0],result.returncode,result.stderr or result.stdout))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--rtl',action='store_true')
    parser.add_argument('--iverilog-dir')
    args=parser.parse_args()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Checks))
    if not result.wasSuccessful(): sys.exit(1)
    if args.rtl:
        if not args.iverilog_dir: parser.error('--rtl requires --iverilog-dir')
        rtl_replay(args.iverilog_dir)
