import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct EditorView: View {
    let item: SymbolItem
    @EnvironmentObject private var store: StudioStore
    @State private var style: ExportStyle
    @State private var glyph: VectorGlyph?
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var shareFile: ShareFile?
    @State private var saving = false
    @State private var designTitle = ""
    @State private var saved = false
    @State private var previewBackground = 0
    @State private var exporting = false
    @State private var exportingDocument = false
    @State private var svgDocument = SVGDocument(text: "")

    init(item: SymbolItem, initialStyle: ExportStyle = ExportStyle()) {
        self.item = item
        _style = State(initialValue: initialStyle)
    }

    var body: some View {
        Form {
            previewSection
            if let glyph {
                paintSection(glyph)
                if style.mode == .parts { partsSection(glyph) }
                layoutSection
                exportSection(glyph)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { store.toggleFavorite(item.name) } label: {
                    Image(systemName: store.favorites.contains(item.name) ? "star.fill" : "star")
                }.accessibilityLabel(store.favorites.contains(item.name) ? "取消收藏" : "收藏")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .task(id: item.name) {
            store.recordRecent(item.name)
            do { glyph = try await GlyphStore.shared.load(item.name) }
            catch { loadError = error.localizedDescription }
        }
        .sheet(item: $shareFile) { ShareSheet(file: $0.url) }
        .fileExporter(isPresented: $exportingDocument, document: svgDocument,
                      contentType: .svg, defaultFilename: item.name) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("保存配色", isPresented: $saving) {
            TextField("配色名称", text: $designTitle)
            Button("保存") { saveDesign() }
            Button("取消", role: .cancel) { }
        } message: { Text("保留颜色、透明度和导出尺寸，方便下次继续编辑。") }
        .alert("已保存", isPresented: $saved) { Button("好", role: .cancel) { } }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var previewSection: some View {
        Section {
            VStack(spacing: 14) {
                ZStack {
                    if previewBackground == 0 { Checkerboard() }
                    else if previewBackground == 1 { Color.white }
                    else { Color(white: 0.12) }
                    if let glyph {
                        GlyphCanvas(glyph: glyph, style: style).padding(14)
                    } else if let loadError {
                        Text(loadError).foregroundStyle(.red).padding()
                    } else { ProgressView() }
                }
                .frame(height: 218)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.gray.opacity(0.12), lineWidth: 1))
                Picker("预览底色", selection: $previewBackground) {
                    Text("棋盘格").tag(0); Text("浅色").tag(1); Text("深色").tag(2)
                }.pickerStyle(.segmented)
            }.padding(.vertical, 6)
        } footer: {
            Text("预览底色用于检查透明区域，不会随透明背景导出。")
        }
    }

    private func paintSection(_ glyph: VectorGlyph) -> some View {
        Section {
            Picker("配色方式", selection: $style.mode) {
                Text("统一配色").tag(PaintMode.uniform)
                if glyph.parts.count > 1 { Text("分部配色").tag(PaintMode.parts) }
            }
            ColorEditor(label: style.mode == .uniform ? "图标颜色" : "默认颜色", value: $style.primary)
            HStack(spacing: 0) {
                ForEach(Array(RGBA.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        style.primary = preset
                    } label: {
                        Circle().fill(preset.color).frame(width: 27, height: 27)
                            .overlay(Circle().stroke(.gray.opacity(0.35), lineWidth: 1))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel(preset.hex)
                }
            }
            ValueSlider(title: "整体不透明度", value: $style.opacity, range: 0...1,
                        valueText: "\(Int((style.opacity * 100).rounded()))%")
        } header: {
            Text("配色")
        } footer: {
            Text(glyph.parts.count > 1 ? "统一配色可使用任意颜色。分部配色可分别调整素材中的 \(glyph.parts.count) 个部分。" : "这个图标是一条完整路径，支持整体改色与半透明。")
        }
    }

    private func partsSection(_ glyph: VectorGlyph) -> some View {
        Section {
            ForEach(glyph.parts.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    partPreview(glyph, index)
                    ColorEditor(label: "部分 \(index + 1)", value: partBinding(index), showsHex: false)
                }
            }
            Button("应用蓝／橙／粉配色") {
                let colors = [RGBA.oceanBlue, RGBA.orange, RGBA.pink]
                for index in glyph.parts.indices { style.partColors[index] = colors[index % colors.count] }
            }
            Button("所有部分恢复默认颜色") { style.partColors = [:] }
        } header: {
            Text("分别调色")
        } footer: {
            Text("每个色盘都可独立调透明度。路径内部的镂空保持不变。")
        }
    }

    private func partPreview(_ glyph: VectorGlyph, _ index: Int) -> some View {
        let partial = VectorGlyph(viewBox: glyph.viewBox, parts: [glyph.parts[index]])
        var local = ExportStyle(); local.primary = style.color(for: index); local.padding = 0.05
        return GlyphCanvas(glyph: partial, style: local)
            .frame(width: 38, height: 38).background(Checkerboard())
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func partBinding(_ index: Int) -> Binding<RGBA> {
        Binding(get: { style.partColors[index] ?? style.primary }, set: { style.partColors[index] = $0 })
    }

    private var layoutSection: some View {
        Section("画布") {
            Picker("导出尺寸", selection: $style.size) {
                ForEach([16, 24, 32, 48, 64, 128, 256, 512, 1024, 2048], id: \.self) { size in
                    Text("\(size) × \(size)").tag(size)
                }
            }
            ValueSlider(title: "四周留白", value: $style.padding, range: 0...0.4,
                        valueText: "\(Int((style.padding * 100).rounded()))%")
            Toggle("透明背景", isOn: $style.transparentBackground)
            if !style.transparentBackground { ColorEditor(label: "背景颜色", value: $style.background) }
        }
    }

    private func exportSection(_ glyph: VectorGlyph) -> some View {
        Section {
            Button {
                svgDocument = SVGDocument(text: StaticExporter.svg(name: item.name, glyph: glyph, style: style))
                exportingDocument = true
            } label: { Label("保存 SVG 到文件", systemImage: "square.and.arrow.down") }
            Button { export(glyph, "svg") } label: { Label("分享 SVG", systemImage: "square.and.arrow.up") }
            Button { export(glyph, "png") } label: { Label("导出 PNG", systemImage: "photo") }
            Button { designTitle = item.name; saving = true } label: {
                Label("保存配色", systemImage: "paintpalette")
            }
            Menu {
                Button("复制 SVG 源码") { UIPasteboard.general.string = StaticExporter.svg(name: item.name, glyph: glyph, style: style) }
                Button("复制图标名称") { UIPasteboard.general.string = item.name }
                Button("导出配色 JSON") { export(glyph, "json") }
            } label: { Label("更多导出选项", systemImage: "ellipsis.circle") }
        } header: {
            Text("保存与导出")
        } footer: {
            Text("SVG 保存真实的矢量路径、颜色和透明度，可继续编辑。PNG 按所选像素尺寸生成。")
        }
        .disabled(exporting)
    }

    private func export(_ glyph: VectorGlyph, _ format: String) {
        exporting = true
        defer { exporting = false }
        do { shareFile = ShareFile(url: try StaticExporter.write(name: item.name, glyph: glyph, style: style, format: format)) }
        catch { errorMessage = error.localizedDescription }
    }
    private func saveDesign() {
        do { try store.saveDesign(name: item.name, title: designTitle, style: style); saved = true }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text(valueText).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: $value, in: range).accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}

struct ColorEditor: View {
    let label: String
    @Binding var value: RGBA
    var showsHex = true
    @State private var input = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColorPicker(label, selection: Binding(get: { value.color }, set: { value = RGBA($0) }), supportsOpacity: true)
            if showsHex {
                HStack(spacing: 10) {
                    Text("HEX").font(.caption).foregroundStyle(.secondary)
                    TextField("#RRGGBB 或 #RRGGBBAA", text: $input)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onSubmit { applyHex() }
                    Button("应用") { applyHex() }.font(.caption)
                }
                if invalid { Text("请输入 6 位颜色或 8 位含透明度的 HEX。") .font(.caption2).foregroundStyle(.red) }
            }
        }
        .onAppear { syncHex() }
        .onChange(of: value) { _ in syncHex() }
    }
    private func syncHex() {
        input = value.hex + (value.alpha < 1 ? String(format: "%02X", Int((value.alpha * 255).rounded())) : "")
        invalid = false
    }
    private func applyHex() {
        if let next = RGBA(hex: input) { value = next; invalid = false }
        else { invalid = true }
    }
}

struct SVGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.svg] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
