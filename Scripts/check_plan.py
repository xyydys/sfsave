#!/usr/bin/env python3
"""Check an icon plan JSON without a device.

    Scripts/check_plan.py plan.json [--catalog SymbolStudio/Resources/catalog.json]

Mirrors the checks the app runs when a plan is imported (field names, values,
colors, file names, output name clashes) and also looks every symbol up in the
bundled catalog. Exit status is 1 when there are errors.
"""
import argparse
import json
import re
import sys
from pathlib import Path

MODES = {'monochrome', 'hierarchical', 'palette', 'multicolor'}
WEIGHTS = {'ultralight', 'thin', 'light', 'regular', 'medium', 'semibold', 'bold', 'heavy', 'black'}
SCALES = {'small', 'medium', 'large'}
FITS = {'contain', 'natural'}
FORMATS = {'png', 'svg'}
APPEARANCES = {'light', 'dark'}
SYSTEM_COLORS = {'red', 'orange', 'yellow', 'green', 'mint', 'teal', 'cyan', 'blue', 'indigo', 'purple',
                 'pink', 'brown', 'white', 'gray', 'black', 'primary', 'secondary', 'tertiary',
                 'quaternary', 'accent'}
STYLE_KEYS = {'mode', 'weight', 'scale', 'pointSize', 'variableValue', 'gradient', 'colors', 'color', 'light',
              'dark', 'canvas', 'padding', 'fit', 'scales', 'formats', 'appearances', 'background'}
ICON_KEYS = {'file', 'aliases', 'symbol', 'note'} | STYLE_KEYS
ROOT_KEYS = {'version', 'name', 'defaults', 'output', 'icons'}
OUTPUT_KEYS = {'darkSuffix', 'darkFolder', 'scaleSuffix', 'svgFolder'}


def ignorable(key):
    return key.startswith('_') or key.startswith('$') or key == 'comment'


def as_list(value):
    return value if isinstance(value, list) else [value]


def valid_path(path):
    if not path or len(path) > 120 or '\\' in path:
        return False
    if any(part in ('', '.', '..') for part in path.split('/')):
        return False
    return all(ord(c) >= 32 and ord(c) != 127 and c not in ':*?"<>|' for c in path)


def valid_color(text):
    if not isinstance(text, str):
        return False
    text = text.strip()
    if text.startswith('#'):
        return re.fullmatch(r'#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})', text) is not None
    return text.lower() in SYSTEM_COLORS


def check(plan, catalog_names):
    errors, warnings = [], []
    err = lambda where, msg: errors.append(f'{where}: {msg}')
    warn = lambda where, msg: warnings.append(f'{where}: {msg}')

    if not isinstance(plan, dict):
        return ['根节点必须是对象'], []
    for key in plan:
        if key not in ROOT_KEYS and not ignorable(key):
            warn('plan', f'未知字段 {key!r}')
    if plan.get('version', 1) != 1:
        warn('plan', f"版本是 {plan.get('version')}，只认识 1")
    defaults = plan.get('defaults') or {}
    for key in defaults:
        if key not in STYLE_KEYS and not ignorable(key):
            warn('defaults', f'未知字段 {key!r}')
    output = plan.get('output') or {}
    for key in output:
        if key not in OUTPUT_KEYS and not ignorable(key):
            warn('output', f'未知字段 {key!r}')
    dark_suffix = output.get('darkSuffix', '_dark')
    dark_folder = output.get('darkFolder', '')
    scale_suffix = output.get('scaleSuffix', '@{n}x')
    svg_folder = output.get('svgFolder', 'svg')
    if '{n}' not in scale_suffix:
        warn('output', 'scaleSuffix 里没有 {n}，@2x 和 @3x 会重名')
    if not dark_suffix and not dark_folder:
        warn('output', 'darkSuffix 和 darkFolder 都是空的，深色会和浅色重名')

    icons = plan.get('icons')
    if not isinstance(icons, list) or not icons:
        err('plan', 'icons 缺失或为空')
        return errors, warnings

    claimed = {}
    for index, icon in enumerate(icons):
        where = f"icons[{index}] {icon.get('file', '') if isinstance(icon, dict) else ''}".strip()
        if not isinstance(icon, dict):
            err(where, '必须是对象')
            continue
        errors_before = len(errors)
        for key in icon:
            if key not in ICON_KEYS and not ignorable(key):
                warn(where, f'未知字段 {key!r}')
        file = icon.get('file')
        symbol = icon.get('symbol')
        if not file:
            err(where, '缺少 file')
            continue
        names = [file] + list(icon.get('aliases') or [])
        if len({n.lower() for n in names}) != len(names):
            err(where, 'file 和 aliases 里有重复的名字')
        for name in names:
            if not valid_path(name):
                err(where, f'文件名不合法：{name!r}')
        if not symbol:
            err(where, '缺少 symbol')
        elif catalog_names is not None and symbol not in catalog_names:
            warn(where, f'符号 {symbol!r} 不在内置索引里（可能是更新的符号，App 会在设备上再检查一次）')

        def pick(key):
            return icon[key] if key in icon else defaults.get(key)

        for key, allowed in (('mode', MODES), ('weight', WEIGHTS), ('scale', SCALES), ('fit', FITS)):
            value = pick(key)
            if value is not None and str(value).lower() not in allowed:
                err(where, f'{key} 不能是 {value!r}，可选：{sorted(allowed)}')
        mode = str(pick('mode') or 'monochrome').lower()
        canvas = pick('canvas')
        if canvas is not None:
            sides = as_list(canvas)
            if len(sides) not in (1, 2) or not all(isinstance(v, (int, float)) and 1 <= v <= 2048 for v in sides):
                err(where, 'canvas 要写成 [宽, 高]，每边 1 到 2048 点')
        padding = pick('padding')
        if padding is not None and not 0 <= padding <= 0.45:
            warn(where, 'padding 要在 0 到 0.45 之间')
        scales = pick('scales') if pick('scales') is not None else [1]
        if (not isinstance(scales, list) or not scales or len(set(scales)) != len(scales)
                or not all(isinstance(v, int) and 1 <= v <= 4 for v in scales)):
            err(where, 'scales 要写成 1 到 4 之间不重复的整数，例如 [2, 3]')
            scales = [1]
        formats = [str(v).lower() for v in as_list(pick('formats') or ['png'])]
        for value in formats:
            if value not in FORMATS:
                err(where, f'formats 里的 {value!r} 不认识')
        for value in as_list(pick('appearances') or []):
            if str(value).lower() not in APPEARANCES:
                err(where, f'appearances 里的 {value!r} 不认识')
        background = pick('background')
        if background is not None and not (isinstance(background, str) and background.startswith('#') and valid_color(background)):
            err(where, f'background 要写成 #RRGGBB 或 #RRGGBBAA：{background!r}')

        def colors(appearance):
            own = icon.get(appearance)
            if own is None:
                own = icon.get('colors', icon.get('color'))
            if own is None:
                own = defaults.get(appearance)
            if own is None:
                own = defaults.get('colors', defaults.get('color'))
            return as_list(own) if own is not None else ['primary']

        has_dark = (icon.get('dark') if 'dark' in icon else defaults.get('dark')) is not None
        appearances = [str(v).lower() for v in as_list(pick('appearances'))] if pick('appearances') else (
            ['light', 'dark'] if has_dark else ['light'])
        for appearance in ('light', 'dark'):
            for color in colors(appearance):
                if not valid_color(color):
                    err(where, f'颜色 {color!r} 看不懂')
        for appearance in appearances:
            count = len(colors(appearance))
            if mode == 'palette' and count < 2:
                warn(where, f'palette 至少要 2 个颜色（{appearance}）')
            elif mode == 'palette' and count > 3:
                warn(where, f'palette 最多用 3 个颜色（{appearance}）')
            elif mode != 'palette' and count > 1:
                warn(where, f'{mode} 只用第一个颜色（{appearance}）')

        # Output file names, case-insensitive like most file systems.
        def base(name, appearance):
            if appearance != 'dark':
                return name
            return (dark_folder + '/' if dark_folder else '') + name + dark_suffix
        paths = []
        for appearance in appearances:
            for name in names:
                if 'png' in formats:
                    paths += [base(name, appearance) + ('' if s == 1 else scale_suffix.replace('{n}', str(s))) + '.png' for s in scales]
                if 'svg' in formats:
                    paths.append((svg_folder + '/' if svg_folder else '') + base(name, appearance) + '.svg')
        for path in paths:
            owner = claimed.get(path.lower())
            if owner is not None:
                err(where, f'输出文件 {path!r} 和 icons[{owner}] 重名')
                break
        # Like the app, only icons without errors claim their file names.
        if len(errors) == errors_before:
            for path in paths:
                claimed[path.lower()] = index
    return errors, warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent / 'SymbolStudio/Resources/catalog.json')
    args = parser.parse_args()
    try:
        plan = json.loads(args.plan.read_text(encoding='utf-8'))
    except json.JSONDecodeError as e:
        sys.exit(f'不是有效的 JSON：{e}')
    names = None
    if args.catalog.is_file():
        names = {s['name'] for s in json.loads(args.catalog.read_text(encoding='utf-8'))['symbols']}
    errors, warnings = check(plan, names)
    for line in warnings:
        print('提醒', line)
    for line in errors:
        print('错误', line)
    icons = plan.get('icons', []) if isinstance(plan, dict) else []
    print(f'{len(icons)} 个图标，{len(errors)} 个错误，{len(warnings)} 个提醒')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
