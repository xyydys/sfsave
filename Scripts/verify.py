#!/usr/bin/env python3
"""Structural/resource checks. Does not replace an Xcode build or device test."""
from pathlib import Path
from collections import Counter
import json
import math
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
resources = ROOT / 'SymbolStudio/Resources'
catalog = json.loads((resources/'catalog.json').read_text())
names = [s['name'] for s in catalog['symbols']]
assert len(names) == 6984 and len(names) == len(set(names))
assert set(names) == {p.stem for p in (resources/'Glyphs').glob('*.json')}
parts = 0
for symbol in catalog['symbols']:
    glyph = json.loads((resources/'Glyphs'/(symbol['name']+'.json')).read_text())
    assert len(glyph['viewBox']) == 4 and glyph['viewBox'][2] > 0 and glyph['viewBox'][3] > 0
    assert len(glyph['parts']) == symbol['partCount']
    for part in glyph['parts']:
        assert part['d'] and 0 <= part['alpha'] <= 1
        commands=part['commands']; i=0
        while i < len(commands):
            op=commands[i]; assert op in (0,1,2,3,4)
            length={0:2,1:2,2:6,3:4,4:0}[op]
            assert i+length < len(commands)
            assert all(math.isfinite(v) for v in commands[i+1:i+1+length])
            i+=length+1
        assert i==len(commands)
        parts+=1
assert parts==13724
assert any('爱心' in s['keywords'] and s['name']=='heart.fill' for s in catalog['symbols'])
assert any('导出' in s['keywords'] and s['name']=='square.and.arrow.up' for s in catalog['symbols'])
plistlib.loads((ROOT/'SymbolStudio/Info.plist').read_bytes())
project=(ROOT/'SymbolStudio.xcodeproj/project.pbxproj').read_text()
for f in (ROOT/'SymbolStudio').glob('*.swift'): assert 'path = "'+f.name+'"' in project
defined=re.findall(r'^\s*([A-F0-9]{24}) = \{',project,re.M)
assert len(defined)==len(set(defined))
allids=set(re.findall(r'\b[A-F0-9]{24}\b',project))
assert allids==set(defined)
ET.parse(ROOT/'SymbolStudio.xcodeproj/xcshareddata/xcschemes/SymbolStudio.xcscheme')
subprocess.run(['bash','-n',str(ROOT/'build.sh')],check=True)
swift_files=list((ROOT/'SymbolStudio').glob('*.swift'))
syntax='not run (optional tree-sitter dependencies missing)'
try:
    from tree_sitter import Language,Parser
    import tree_sitter_swift
    parser=Parser(Language(tree_sitter_swift.language()))
    for f in swift_files: assert not parser.parse(f.read_bytes()).root_node.has_error, f
    syntax=f'{len(swift_files)} files passed'
except ImportError: pass
report={'symbols':len(names),'paths':parts,'resource_structure':'passed',
        'project_references':'passed','build_script_syntax':'passed','swift_syntax':syntax,
        'ios_sdk_build':'not run — Xcode unavailable','simulator_and_device':'not run'}
(ROOT/'Verification/verification.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print(json.dumps(report,indent=2,ensure_ascii=False))
