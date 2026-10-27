# 符号工坊 SymbolStudio 0.4.0

iPhone / iPad 原生 SwiftUI 应用：查找 SF Symbols，按系统的渲染方式配色，导出 **SVG / PNG**，并复制 **SwiftUI / UIKit / Objective-C** 代码。

## 工作方式

App 不内置任何图标图形。导出时让 SwiftUI 按所选样式绘制符号（与复制出去的 SwiftUI 代码完全相同），绘制进 PDF，再把 PDF 里的矢量路径转换成 SVG：

```
Image(systemName:) + 样式  →  ImageRenderer 绘制到 PDF  →  PDFVectorExtractor（CGPDFScanner）→  SVGWriter  →  .svg
```

因此 SVG 里的分层、颜色、层级透明度、多色和渐变都来自系统本身，和当前 iOS 版本的符号一致，不需要随 App 打包 37 MB 的路径数据。

系统用“软蒙版”实现徽标等图层的镂空（clear behind），转换时会写成 SVG `<mask>`。UIKit 把 `UIImage` 符号画进 PDF 时会变成位图，所以只用 SwiftUI 绘制。

## 功能

- 渲染模式：单色 Monochrome / 分层 Hierarchical / 调色板 Palette（2–3 层分别配色）/ 多色 Multicolor
- 渐变 Gradients（SF Symbols 7，`symbolColorRenderingMode(.gradient)`，需要 iOS 26）
- 颜色：系统色（红、橙…棕、白、灰、黑）、语义色（Primary、Secondary、Tertiary、Quaternary、Accent）、自定义（取色器或 HEX）
- 九种粗细、小 / 中 / 大三种比例、字号、可变值 Variable Value
- 语义色按所选外观（浅色 / 深色）解析成具体颜色写入 SVG
- 画布：原始尺寸（保留排版框，便于与文字对齐）或 16–2048 像素正方形画布，可调留白、透明或纯色背景
- 预览可在“系统渲染”和“导出的 SVG”（用 WebKit 显示导出的文件本身）之间切换，用来核对转换结果
- 保存 SVG 到“文件”、分享 SVG、导出 PNG、复制 SVG 源码、复制代码、保存配色
- 高级：可导出系统绘制的原始 PDF，用于排查转换问题

复制的 SwiftUI 代码示例：

```swift
Image(systemName: "xmark")
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(.secondary)
```

## 逐个替换（抓到的图标）

「逐个替换」页导入抓图工具导出的 zip（`manifest.json` + `icons/`），把每个素材名列出来，同名的多次抓取合并成一项，记下微信要的尺寸、上色和旋转角度，以及原图内容所在的矩形。

- 每个素材可以选“替换 / 不替换 / 待定”，挑符号（先给几个按用途挑好的候选，也能在全部符号里搜），再选一种风格：极光、日落、青柠、樱花（渐变），霓虹、撞色、糖果（分层多色），官方多色，四种带底座的“徽章”，或保留微信原色。
- “自定义”里能改渲染模式、每一层的纯色或渐变、渐变角度、粗细、底座形状和颜色、大小。
- “一键套用风格”把一种风格套到所有待定的图标上（装饰类素材和标了不替换的不动），然后再逐个细调。
- 导出的 zip 按微信素材名命名（`name@3x.png`、`svg/name.svg`），画布和原图一样大，图形放在原图内容所在的位置；另附 `plan.json`，可以在「批量导出」页重新导入。

候选符号和“装饰类”标记来自 `SymbolStudio/Resources/wechat-suggestions.json`（由 `Scripts/wechat_suggestions.py` 生成，覆盖微信 8.0.73 抓到的 336 个素材）；不在表里的素材按名字里的英文单词猜。

## 批量导出（图标方案）

“批量导出”页读取一份 JSON 方案：每个图标写明输出文件名、用哪个 SF Symbol、渲染模式、浅色和深色配色、尺寸和倍率。点一下导出，得到一个 zip，里面的文件已经按方案命名：

```
tab_home@2x.png        tab_home@3x.png
tab_home_dark@2x.png   tab_home_dark@3x.png
svg/nav_search.svg
manifest.json          （每个文件的路径、符号、外观、像素尺寸；被跳过的项目和原因）
```

图标会按 `canvas`（点）和 `fit` 排进固定大小的画布：`contain` 把图形放大到填满画布（减去 `padding`），`natural` 保持渲染字号只做居中。PNG 的像素尺寸是 `canvas × 倍率`，可直接给 @2x / @3x 资源用。

方案示例见 `SymbolStudio/Resources/sample-plan.json`（App 里“载入示例方案”或“复制示例 JSON”即可）。字段：

| 字段 | 说明 |
| --- | --- |
| `icons[].file` | 输出文件名，不含扩展名，可含子文件夹 `a/b`；必填 |
| `icons[].aliases` | 其他文件名，每个名字各输出一份 |
| `icons[].symbol` | SF Symbol 名称；必填 |
| `mode` | `monochrome` / `hierarchical` / `palette` / `multicolor` |
| `light` / `dark` / `colors` / `color` | 颜色列表，`#RRGGBB`、`#RRGGBBAA` 或系统色名（`blue`、`secondary`…）。`palette` 用 2–3 个，其他模式只用第一个。`colors` 浅色深色共用；只要写了 `dark` 就会同时导出深色版 |
| `gradient` | 渐变（需要 iOS 26） |
| `weight` / `scale` / `pointSize` / `variableValue` | 粗细、比例、字号、可变值 |
| `canvas` / `padding` / `fit` | 画布 `[宽, 高]`（点）、四周留白（0–0.45）、`contain` 或 `natural` |
| `box` | `[x, y, 宽, 高]`（点）：把图形放进画布里的这个矩形并居中，代替 `padding`。替换现有图标时，填原图内容所在的矩形，新图标就和原图对齐 |
| `scales` / `formats` / `appearances` | 倍率如 `[2, 3]`、`png` / `svg`、`light` / `dark` |
| `background` | 背景色，默认透明 |
| `fills` / `fillAngle` | 每层的填充，替代颜色：`#RRGGBB` 是纯色，`#起始色>#结束色` 是线性渐变；`fillAngle` 是渐变方向（度，默认 45，从左上到右下） |
| `badge` | 底座：`{"shape": "circle" 或 "squircle", "fill": "#6A5CFF>#C04CFD", "glyph": 0.5}`，符号画在填色的圆形或圆角方形上，`glyph` 是符号相对底座的大小 |
| `output` | `darkSuffix`（默认 `_dark`）、`darkFolder`、`scaleSuffix`（默认 `@{n}x`）、`svgFolder`（默认 `svg`） |

除了 `file` 和 `symbol`，其他字段都可以写在 `defaults` 里，再在单个图标里覆盖。以 `_`、`$` 开头的字段和 `comment` 会被忽略，可以写备注。

方案有三种导入方式：在「批量导出」页点“导入方案 JSON…”从“文件”里选；在“文件”或聊天 App 里点 JSON 文件，选“用其他应用打开”→ 符号工坊；或者复制 JSON 全文，再点“从剪贴板导入”。

导入时 App 会逐项检查：符号在这个系统里是否存在、颜色是否看得懂、文件名是否合法或重名、字段是否拼错。有错误的图标不会导出，其余照常导出，问题列表就显示在页面上。也可以先在电脑上检查：

```bash
python3 Scripts/check_plan.py my-plan.json
```

## SVG 内容

- `<path>` 带十六进制颜色和 `fill-opacity`；路径坐标已换算到画布，无需额外变换
- 渐变写成 `<linearGradient>` / `<radialGradient>`，裁剪写成 `<clipPath>`，系统用到的软蒙版写成 `<mask>`
- 系统绘制里如果出现位图或文字（正常不会），预览下方会给出警告

## 编译与安装

最低部署版本 **iOS 16.0**；渐变需要用 Xcode 26 / iOS 26 SDK 编译并在 iOS 26 上运行。

### 只有 iPhone：用 GitHub Actions

推送到任意分支都会触发 **Build SymbolStudio**（也可在 Actions 页面手动运行），步骤：

1. 在 macOS 26 / Xcode 26 上编译未签名 IPA，上传为 `SymbolStudio-unsigned-ipa` 产物
2. 编译模拟器版本，启动 App 的渲染自检（`Scripts/selftest.sh`），把一组典型符号转成 SVG 并检查结果；日志和 SVG 上传为 `SymbolStudio-selftest`

下载 IPA 后用自己的方式签名安装（开发证书、侧载工具等）。

### 有 Mac

打开 `SymbolStudio.xcodeproj`，在 Signing & Capabilities 选择自己的 Team 后运行；或者：

```bash
./build.sh            # 未签名 IPA：build/SymbolStudio_0.3.0_unsigned.ipa
./build.sh simulator  # 模拟器版本
Scripts/selftest.sh   # 在模拟器里跑渲染自检
```

## 工程结构

| 文件 | 作用 |
| --- | --- |
| `SymbolRenderer.swift` | `StyledSymbol` 视图、SwiftUI 绘制到 PDF、PNG 导出 |
| `PDFVectorExtractor.swift` | 用 CGPDFScanner 读取 PDF 的路径、颜色、透明度、裁剪、渐变、蒙版 |
| `SVGWriter.swift` | 排版（原始尺寸 / 画布）并输出 SVG |
| `CodeGenerator.swift` | 生成 SwiftUI、UIKit、Objective-C 代码 |
| `EditorView.swift` | 编辑页面 |
| `IconPlan.swift` | 图标方案 JSON 的解码、检查和命名规则 |
| `BatchExporter.swift` / `BatchView.swift` | 批量渲染并打包 / 批量导出页面 |
| `ZipWriter.swift` | 直接写入磁盘的 zip（不压缩，含 CRC32） |
| `LibraryView.swift` | 图标库、我的配色、关于 |
| `SelfTest.swift` | `-SymbolStudioSelfTest` 启动参数下的渲染自检 |
| `Resources/catalog.json` | 名称、分类、中英文搜索关键词（不含图形） |
| `Resources/sample-plan.json` | 示例图标方案 |
| `Scripts/check_plan.py` | 在电脑上检查图标方案 JSON |
| `Scripts/build_catalog.py` | 从 SF Symbols App 的 Metadata 重新生成 catalog.json |
| `Scripts/make_project.py` | 生成 Xcode 工程（增删 Swift 文件后运行） |
| `Scripts/verify.py` | 不依赖 Xcode 的结构检查 |

## 许可

SF Symbols 的图形权利属于 Apple。导出的 SVG / PNG 只适合用于 Apple 平台的应用设计与开发，并需遵守 Apple 的 [SF Symbols 许可条款](https://developer.apple.com/sf-symbols/)。
