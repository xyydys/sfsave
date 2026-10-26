#!/usr/bin/env python3
from pathlib import Path
import plistlib
import zipfile

root=Path(__file__).resolve().parent.parent
app=root/'build/DerivedData/Build/Products/Release-iphoneos/SymbolStudio.app'
if not (app/'SymbolStudio').is_file():
    raise SystemExit('找不到编译完成的 SymbolStudio.app')
if not (app/'catalog.json').is_file():
    raise SystemExit('构建结果缺少图标索引，停止打包')
version=plistlib.loads((app/'Info.plist').read_bytes()).get('CFBundleShortVersionString','0')
out=root/f'build/SymbolStudio_{version}_unsigned.ipa'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.rglob('*')):
        if file.is_file(): archive.write(file,'Payload/SymbolStudio.app/'+file.relative_to(app).as_posix())
print('已打包未签名 IPA：',out)
print('普通设备需使用你自己的开发签名或侧载签名后安装。')
