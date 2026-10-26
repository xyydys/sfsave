#!/usr/bin/env python3
"""Structural checks that run without Xcode. They do not replace the Xcode
build or the simulator self-test in CI (Scripts/selftest.sh)."""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
catalog = json.loads((ROOT/'SymbolStudio/Resources/catalog.json').read_text())
names = [s['name'] for s in catalog['symbols']]
assert names and len(names) == len(set(names))
categories = {c['id'] for c in catalog['categories']}
assert all(set(s['categories']) <= categories for s in catalog['symbols'])
assert any('爱心' in s['keywords'] and s['name'] == 'heart.fill' for s in catalog['symbols'])
plistlib.loads((ROOT/'SymbolStudio/Info.plist').read_bytes())
project = (ROOT/'SymbolStudio.xcodeproj/project.pbxproj').read_text()
swift_files = sorted((ROOT/'SymbolStudio').glob('*.swift'))
for f in swift_files: assert 'path = "'+f.name+'"' in project, f.name
assert project.count('sourcecode.swift') == len(swift_files)
defined = re.findall(r'^\s*([A-F0-9]{24}) = \{', project, re.M)
assert len(defined) == len(set(defined))
assert set(re.findall(r'\b[A-F0-9]{24}\b', project)) == set(defined)
ET.parse(ROOT/'SymbolStudio.xcodeproj/xcshareddata/xcschemes/SymbolStudio.xcscheme')
for script in ['build.sh', 'Scripts/selftest.sh']:
    subprocess.run(['bash', '-n', str(ROOT/script)], check=True)
syntax = 'not run (pip install tree-sitter tree-sitter-swift to enable)'
try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    parser = Parser(Language(tree_sitter_swift.language()))
    for f in swift_files:
        tree = parser.parse(f.read_bytes())
        assert not tree.root_node.has_error, f.name
    syntax = f'{len(swift_files)} files passed'
except ImportError:
    pass
print(json.dumps({'symbols': len(names), 'swift_files': len(swift_files), 'project_references': 'passed',
                  'swift_syntax': syntax}, ensure_ascii=False, indent=2))
