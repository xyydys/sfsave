# 符号工坊 SymbolStudio 0.2.0

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
./build.sh            # 未签名 IPA：build/SymbolStudio_0.2.0_unsigned.ipa
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
| `LibraryView.swift` | 图标库、我的配色、关于 |
| `SelfTest.swift` | `-SymbolStudioSelfTest` 启动参数下的渲染自检 |
| `Resources/catalog.json` | 名称、分类、中英文搜索关键词（不含图形） |
| `Scripts/build_catalog.py` | 从 SF Symbols App 的 Metadata 重新生成 catalog.json |
| `Scripts/make_project.py` | 生成 Xcode 工程（增删 Swift 文件后运行） |
| `Scripts/verify.py` | 不依赖 Xcode 的结构检查 |

## 许可

SF Symbols 的图形权利属于 Apple。导出的 SVG / PNG 只适合用于 Apple 平台的应用设计与开发，并需遵守 Apple 的 [SF Symbols 许可条款](https://developer.apple.com/sf-symbols/)。
