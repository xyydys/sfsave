#!/usr/bin/env python3
"""Prepare bundled vector geometry from pinned SF Symbols SVG exports.

Dependencies: fonttools, lxml. Inputs are paths, never executed as code.
All contours in one source <path> stay together, preserving holes.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import plistlib
import re
from lxml import etree
from fontTools.svgLib.path import parse_path
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen

CATEGORY_NAMES = {
    'communication': '交流', 'weather': '天气', 'maps': '地图',
    'objectsandtools': '物品与工具', 'devices': '设备', 'cameraandphotos': '相机与照片',
    'gaming': '游戏', 'connectivity': '连接', 'transportation': '交通',
    'automotive': '汽车', 'accessibility': '辅助功能', 'privacyandsecurity': '隐私与安全',
    'human': '人物', 'home': '家居', 'fitness': '运动', 'nature': '自然',
    'editing': '编辑', 'textformatting': '文字格式', 'media': '媒体',
    'keyboard': '键盘', 'commerce': '购物与支付', 'time': '时间',
    'health': '健康', 'shapes': '形状', 'arrows': '箭头', 'indices': '字符与数字',
    'math': '数学'
}
WORDS = {
    'heart': '爱心 心脏 喜欢 收藏', 'star': '星星 收藏 评分', 'house': '房子 首页 主页 家',
    'home': '首页 主页 家', 'person': '人 用户 个人 账号 联系人', 'people': '群组 多人',
    'message': '消息 聊天 信息', 'bubble': '气泡 聊天 对话', 'phone': '电话 手机',
    'envelope': '信封 邮件 邮箱', 'camera': '相机 拍照', 'photo': '照片 相片 图片 相册',
    'image': '图片 图像', 'video': '视频 录像', 'mic': '麦克风 语音 录音',
    'speaker': '声音 扬声器 音量', 'music': '音乐 歌曲', 'play': '播放', 'pause': '暂停',
    'stop': '停止', 'forward': '快进 前进', 'backward': '快退 后退',
    'arrow': '箭头 方向', 'chevron': '返回 箭头 展开', 'left': '左 返回', 'right': '右 前进',
    'up': '上 向上', 'down': '下 向下 下载', 'plus': '加 新增 添加',
    'minus': '减 减少', 'xmark': '关闭 取消 删除 叉', 'checkmark': '勾 对勾 完成 确认',
    'magnifyingglass': '搜索 查找 放大镜', 'gear': '设置 齿轮', 'slider': '调整 设置 滑块',
    'sliderhorizontal': '调整 滑块', 'ellipsis': '更多 菜单', 'line': '线条 菜单',
    'trash': '垃圾 删除 回收站', 'pencil': '铅笔 编辑 写作', 'square': '方形 方框 正方形',
    'circle': '圆形 圆圈', 'triangle': '三角形', 'rectangle': '矩形 长方形',
    'fill': '实心 填充', 'badge': '标记 徽标 角标', 'slash': '禁止 关闭 斜线',
    'folder': '文件夹 目录', 'doc': '文档 文件', 'paperplane': '发送 纸飞机',
    'paperclip': '附件 回形针', 'link': '链接', 'network': '网络', 'wifi': '无线 网络 信号',
    'antenna': '天线 信号', 'battery': '电池 电量', 'bolt': '闪电 充电',
    'lock': '锁 安全 隐私', 'key': '钥匙 密码', 'eye': '眼睛 显示 查看',
    'bell': '铃铛 通知 提醒', 'clock': '时钟 时间', 'calendar': '日历 日期',
    'timer': '计时器 倒计时', 'alarm': '闹钟', 'sun': '太阳 晴天', 'moon': '月亮 夜晚',
    'cloud': '云 天气', 'rain': '雨 下雨', 'snow': '雪 下雪', 'wind': '风',
    'thermometer': '温度 温度计', 'flame': '火 热门', 'drop': '水滴', 'leaf': '树叶 自然',
    'tree': '树 自然', 'flower': '花', 'car': '汽车 车 交通', 'bus': '公交 巴士',
    'tram': '电车 地铁', 'train': '火车', 'airplane': '飞机 旅行', 'bicycle': '自行车 骑行',
    'location': '位置 定位', 'map': '地图', 'mappin': '地图 定位 标记', 'globe': '地球 全球',
    'cart': '购物车 购物', 'bag': '购物袋 商店', 'creditcard': '银行卡 信用卡 支付',
    'dollarsign': '钱 美元 支付', 'yensign': '钱 人民币 日元', 'gift': '礼物',
    'book': '书 阅读', 'bookmark': '书签 收藏', 'list': '列表 清单', 'chart': '图表 数据',
    'flag': '旗帜 标记', 'hand': '手 手势', 'thumbsup': '点赞 赞', 'smiley': '笑脸 表情',
    'face': '人脸 表情', 'figure': '人物 运动', 'run': '跑步', 'walk': '走路 步行',
    'gamecontroller': '游戏 手柄', 'display': '屏幕 显示器', 'desktopcomputer': '电脑 台式机',
    'laptopcomputer': '笔记本 电脑', 'iphone': '苹果 手机', 'ipad': '平板',
    'applewatch': '手表', 'airpods': '耳机', 'headphones': '耳机', 'keyboard': '键盘',
    'paintbrush': '画笔 配色', 'paintpalette': '调色板 颜色', 'crop': '裁剪',
    'scissors': '剪刀 剪切', 'wand': '魔法 自动', 'sparkles': '闪光 星光',
    'cube': '立方体 三维', 'qrcode': '二维码', 'barcode': '条形码',
    'handshake': '握手 合作', 'shield': '盾牌 安全', 'cross': '十字 医疗',
    'pill': '药 药片 医疗', 'stethoscope': '听诊器 医疗', 'waveform': '波形 音频',
    'arrowshape': '箭头 转发 返回', 'squareandarrow': '分享 导出',
}

def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')

def encode_path(d):
    pen = RecordingPen(); parse_path(d, pen)
    commands = []
    for op, points in pen.value:
        code, expected = {'moveTo': (0, 1), 'lineTo': (1, 1), 'curveTo': (2, 3),
                          'qCurveTo': (3, 2), 'closePath': (4, 0)}[op]
        assert len(points) == expected, (op, points)
        commands.append(code)
        for point in points:
            commands.extend(round(float(v), 6) for v in point)
    return commands

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--svg-dir', type=pathlib.Path, required=True)
    parser.add_argument('--metadata-dir', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    paths_dir = args.output / 'Glyphs'; paths_dir.mkdir(parents=True, exist_ok=True)
    categories = plistlib.loads((args.metadata_dir / 'symbol_categories.plist').read_bytes())
    search = plistlib.loads((args.metadata_dir / 'symbol_search.plist').read_bytes())
    category_defs = plistlib.loads((args.metadata_dir / 'categories.plist').read_bytes())
    known_categories = {x['key']: x for x in category_defs if x['key'] in CATEGORY_NAMES}
    entries = []; counts = collections.Counter(); alpha_parts = 0; empty_parts = 0; sha = hashlib.sha256()
    parser_xml = etree.XMLParser(resolve_entities=False, no_network=True)
    for file in sorted(args.svg_dir.glob('*.svg')):
        raw = file.read_bytes(); sha.update(file.name.encode()); sha.update(raw)
        root = etree.fromstring(raw, parser_xml); name = file.stem
        box = list(map(float, root.attrib['viewBox'].split()))
        assert box[2] > 0 and box[3] > 0
        layers = []
        for node in root.iter():
            if not isinstance(node.tag, str): continue
            tag = etree.QName(node).localname
            assert tag in {'svg', 'g', 'rect', 'path'}, (file, tag)
            if tag == 'rect':
                assert float(node.get('opacity', '1')) == 0
            if tag != 'path': continue
            assert not node.get('transform') and not node.get('stroke')
            d = node.attrib['d']
            if not d.strip():
                empty_parts += 1
                continue
            alpha = round(float(node.get('fill-opacity', '1')) / .85, 6)
            assert 0 <= alpha <= 1
            alpha_parts += alpha < 1
            bounds = BoundsPen(None); parse_path(d, bounds)
            if bounds.bounds:
                x0, y0, x1, y1 = bounds.bounds
                assert x0 >= box[0] - .02 and y0 >= box[1] - .02, (name, bounds.bounds, box)
                assert x1 <= box[0]+box[2]+.02 and y1 <= box[1]+box[3]+.02, (name, bounds.bounds, box)
            layers.append({'d': d, 'commands': encode_path(d), 'alpha': alpha})
        assert layers
        dump(paths_dir / (name + '.json'), {'viewBox': box, 'parts': layers})
        cats = [c for c in categories.get(name, []) if c in known_categories]
        counts.update(cats)
        tokens = re.split(r'[.0-9]+', name)
        words = list(search.get(name, []))
        for token in tokens:
            words.extend(WORDS.get(token, '').split())
        words.extend(CATEGORY_NAMES[c] for c in cats)
        if name == 'square.and.arrow.up': words += ['分享', '导出', '上传']
        if name == 'square.and.arrow.down': words += ['下载', '保存']
        entries.append({'name': name, 'categories': cats,
                        'keywords': ' '.join(dict.fromkeys(words)), 'partCount': len(layers)})
    catalog = {'version': 'SF Symbols 7 SVG snapshot', 'weight': 'Regular',
               'sourceCommit': 'ce617cfd9307067627789fda3a9900af5598b0fe',
               'categories': [{'id': c['key'], 'title': CATEGORY_NAMES[c['key']],
                               'icon': c['icon'], 'count': counts[c['key']]}
                              for c in category_defs if c['key'] in known_categories and counts[c['key']]],
               'symbols': entries}
    dump(args.output / 'catalog.json', catalog)
    report = {'symbols': len(entries), 'multipartSymbols': sum(x['partCount'] > 1 for x in entries),
              'parts': sum(x['partCount'] for x in entries), 'semiTransparentParts': alpha_parts,
              'sourceFilesSHA256': sha.hexdigest(), 'geometryChecks': 'all paths parsed; holes kept; bounds checked',
              'rasterImagesEmbedded': 0, 'externalReferences': 0, 'emptyPathsRemoved': empty_parts, 'weight': 'Regular'}
    dump(args.output / 'resource-report.json', report)
    print(json.dumps(report, indent=2, ensure_ascii=False))

if __name__ == '__main__': main()
