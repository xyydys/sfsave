# 符号工坊 SymbolStudio 0.1.0

一个 iPhone / iPad 原生 SwiftUI 工程，用于离线查找 SF Symbols 图标，调整颜色和透明度，并保存真正的静态 SVG。

## 这一版已经包含

- **6,984 个**内置矢量图标，不需要首次运行再下载资源。
- 名称、英文关键词、常用中文关键词搜索，以及中文分类。
- 网格 / 列表切换、收藏、最近使用。
- 任意单色，包含黑白快捷预设、系统颜色选择器、HEX 输入。
- **4,213 个**具有多个独立路径的图标可以逐部分改色。每个部分支持独立透明度。
- 整体透明度；透明背景或自定义背景；画布尺寸与四边等比例留白。
- 保存配色方案，重新打开后继续修改。
- **保存 SVG 到“文件”**、分享 SVG、透明 PNG、复制 SVG 源码与图标名称。
- 配色 JSON 导出，便于保留参数；当前版本暂不提供 JSON 导入。

SVG 中保存 `<path>`、十六进制颜色、`fill-opacity` 和整体 `opacity`。没有嵌入 PNG，没有外部字体依赖，没有动画。

## 使用

1. 在“图标”页搜索，例如“返回”“聊天”“爱心”“天气”或 `cloud.sun.rain.fill`。
2. 点开图标，使用“统一配色”修改整图颜色。黑白只是预设，不是颜色限制。
3. 图标含多个路径时，可切换“分部配色”。每一行的小预览显示它对应的部分。
4. 用棋盘格检查透明度；白色图标可切换深色预览底色。
5. 调整画布尺寸和留白。选择“透明背景”时，预览用的棋盘格、浅色、深色不会导出。
6. 点“保存 SVG 到文件”，直接选择保存位置；或点“分享 SVG”。

HEX 支持 `#RRGGBB` 和 `#RRGGBBAA`，最后两位是透明度。整体透明度与单独颜色的透明度会相乘。

## 范围

- 当前矢量库是 **Regular 常规粗细**。没有通过加描边模拟九种粗细，也没有显示无效的粗细选项。
- 这份资源有 6,984 个名称，并不保证覆盖 SF Symbols 7 的所有小版本、地区变体和别名。
- “分部配色”编辑的是导出素材内现有的独立路径，不等同于 Apple 的原生调色板 / 多色分组。单个路径中的多个轮廓一起着色，镂空不会被拆散。
- 初始显示使用自选单色，不自动恢复 Apple 为部分符号指定的多色配色。
- 原始 SVG 的通用黑色是 85% 不透明。本工程将这层统一的系统标签淡化归一化到 100%，同时保留原来 50% / 25% 的相对半透明部分。之后由颜色面板和整体透明度控制。
- PNG 导出是静态像素图；SVG 导出仍然是可以无损缩放的路径图。

## 编译与安装

最低部署版本 **iOS 16.0**。可使用 Xcode 16 或更新版本；使用更新 SDK 编译时，系统原生控件的外观由对应系统处理。

### 有 Mac

打开 `SymbolStudio.xcodeproj`，在 Signing & Capabilities 选择自己的 Team，按需更换 Bundle Identifier，选择设备后运行。

如只需要生成未签名 IPA，在工程根目录运行：

```bash
chmod +x build.sh && ./build.sh
```

输出：`build/SymbolStudio_0.1.0_unsigned.ipa`。普通设备需要使用自己的开发签名或侧载签名后才能安装。

模拟器构建：

```bash
./build.sh simulator
```

### 只有 iPhone，使用 GitHub 编译

1. 将本压缩包解压后的**全部工程文件**推送到自己的 GitHub 仓库根目录，包括 `.github/workflows/build.yml`。
2. 打开仓库 Actions，运行 **Build SymbolStudio**。向 main / master 推送也会自动触发。
3. 构建成功后下载 **SymbolStudio-0.1.0-unsigned** 产物，解压得到 IPA，再按自己的方式签名安装。

这是原生 App 工程，不是 Theos 插件；`build.sh` 需要 Mac 的完整 Xcode，不能直接在 iPhone 终端编译。工作流不需要上传开发者证书，也不会自动发布 App。

## 验证状态

已完成：

- 6,984 份矢量数据的 XML / 路径转换、索引对应、路径边界和非空检查。
- 13,724 个有效路径部分的解析；剔除源素材中 3 个空路径；保留复合路径及非零绕组填充规则。
- Swift 源文件的语法树检查，Info.plist / 工程结构和构建脚本检查。
- 常见图标、多部分配色、半透明、白色、镂空的静态 SVG 渲染检查。

**当前制作环境是 Linux，没有 Xcode，因此尚未完成 iOS SDK 编译、模拟器运行或真机验证。** 这是供编译与测试的第一版源码工程，不是已经通过真机测试的安装包。`Verification/` 内为静态矢量验证素材，不能视为 App 真机截图。

## 工程结构

- `SymbolStudio/`：SwiftUI 页面、颜色参数、保存逻辑、SVG / PNG 导出。
- `SymbolStudio/Resources/catalog.json`：名称、分类和搜索关键词。
- `SymbolStudio/Resources/Glyphs/`：每个图标的路径、绘图命令与相对透明度。
- `Scripts/build_catalog.py`：资源预处理脚本，普通编译**不需要运行**。
- `Scripts/make_project.py`：生成已附带的 Xcode 工程，普通编译**不需要运行**。
- `build.sh`：Mac 编译入口；`.github/workflows/build.yml`：GitHub 构建流程。

不依赖第三方 Swift 包，不需要网络服务，不注入其他应用。

## 资源来源

- SF Symbols 7 SVG 快照：[001ProMax/SF-Symbol](https://github.com/001ProMax/SF-Symbol)，固定提交 `ce617cfd9307067627789fda3a9900af5598b0fe`，使用 `light` 目录。
- 分类与英文关键词：Apple 官方 SF Symbols 7 安装包中的 Metadata（下载时应用版本 7.2）。
- 中文类别与常用搜索词：本工程补充；它们不是完整的逐条官方中文翻译。
- Apple 官方入口：[SF Symbols](https://developer.apple.com/sf-symbols/)。

SF Symbols 图形属于 Apple，本工程对资源的打包与配色不改变其许可。它们不是可任意再分发或跨平台使用的开源图标库；导出素材用于 Apple 平台应用设计与开发时仍应遵守 Apple 的条款。
