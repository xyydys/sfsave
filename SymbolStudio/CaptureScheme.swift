import Foundation
import SwiftUI

/// A replacement scheme in progress, to hand to someone else or to another
/// device: the global style, every icon's choice (symbol, own look, size and
/// position nudge, kept or replaced) and, optionally, the imported originals.
/// Written as `scheme.json` in a zip, with the originals under `icons/`.
struct CaptureScheme: Codable {
    static let kind = "symbolstudio-scheme"
    static let currentVersion = 1

    var kind = CaptureScheme.kind
    var version = CaptureScheme.currentVersion
    var name: String
    var note: String?
    /// The app version that wrote it.
    var app: String?
    /// The WeChat version of the originals.
    var wechat: String?
    var generated: Date
    var global: GlobalStyle
    /// By WeChat resource name.
    var choices: [String: IconChoice]
    /// The originals' details, when the zip carries their images.
    var icons: [CaptureIcon]?

    var replacedCount: Int { choices.values.filter(\.replace).count }
    var keptCount: Int { choices.count - replacedCount }
}

/// A scheme read from a file, with the original images it carries by file name.
struct SchemePackage: Identifiable {
    let id = UUID()
    var scheme: CaptureScheme
    var images: [String: Data]

    /// The originals that came with their image.
    var icons: [CaptureIcon] {
        (scheme.icons ?? []).filter { images[$0.image] != nil && SchemeReader.isValidName($0.name) }
    }

    /// Reads a scheme zip, or a bare `scheme.json`. `nil` when the data is
    /// something else, such as a capture zip or a plugin template.
    static func read(_ data: Data) throws -> SchemePackage? {
        if data.starts(with: [0x50, 0x4B]) {
            let zip = try ZipReader(data: data)
            guard let entry = zip.entries
                .filter({ $0.path == "scheme.json" || $0.path.hasSuffix("/scheme.json") })
                .min(by: { $0.path.count < $1.path.count }) else { return nil }
            let folder = String(entry.path.dropLast("scheme.json".count)) + "icons/"
            let scheme = try SchemeReader.decode(zip.read(entry))
            var images: [String: Data] = [:]
            for item in zip.entries where item.path.hasPrefix(folder) && !item.isDirectory {
                let name = String(item.path.dropFirst(folder.count))
                guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { continue }
                images[name] = try zip.read(item)
            }
            return SchemePackage(scheme: scheme, images: images)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == CaptureScheme.kind else { return nil }
        return SchemePackage(scheme: try SchemeReader.decode(data), images: [:])
    }
}

enum SchemeReader {
    static func decode(_ data: Data) throws -> CaptureScheme {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["kind"] as? String != CaptureScheme.kind {
                throw StudioError.resource("这不是符号工坊的方案文件。")
            }
            if let version = object["version"] as? Int, version > CaptureScheme.currentVersion {
                throw StudioError.resource("这个方案是新版符号工坊做的，请先更新 App 再导入。")
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var scheme = try decoder.decode(CaptureScheme.self, from: data)
            scheme.choices = scheme.choices.filter { isValidName($0.key) }
            return scheme
        } catch {
            throw StudioError.resource("方案文件读不懂：\(error.localizedDescription)")
        }
    }

    static func encode(_ scheme: CaptureScheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(scheme)
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && IconPlan.isValidPath(name)
    }
}

/// What importing a scheme would change in the current project.
struct SchemeSummary {
    /// Icons in the scheme that this project does not have yet.
    var newIcons = 0
    /// Icons here without a decision that the scheme decides.
    var fills = 0
    /// Icons decided here and decided differently in the scheme.
    var conflicts = 0
    /// Decided the same way in both.
    var same = 0
    /// Decisions for icons neither here nor carried by the scheme.
    var unknown = 0
}

struct SchemeImportOptions {
    /// Take the scheme's global style (colors, weight, sizing).
    var useGlobal = true
    /// Icons decided both here and in the scheme take the scheme's decision.
    var overwrite = false
    /// Add the scheme's icons this project does not have, with their originals.
    var addIcons = true
}

struct SchemeImportResult {
    var addedIcons: Int
    var applied: Int
    var skipped: Int
}

// MARK: - Views

struct SchemeExportSheet: View {
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "我的微信图标方案"
    @State private var note = ""
    @State private var includeOriginals = true
    @State private var file: URL?
    @State private var shareFile: ShareFile?
    @State private var saved = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("方案名", text: $name)
                    TextField("备注（可不填）", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("方案")
                }
                Section {
                    LabeledContent("已替换", value: "\(capture.choices.values.filter(\.replace).count) 个")
                    LabeledContent("不替换", value: "\(capture.choices.values.filter { !$0.replace }.count) 个")
                    LabeledContent("单独设置风格", value: "\(capture.styleCounts.own) 个")
                    LabeledContent("单独调过大小位置", value: "\(capture.adjustedCount) 个")
                } header: {
                    Text("会带上")
                } footer: {
                    Text("全局风格（配色、粗细、尺寸统一）和每个图标的设置：选的符号、替换还是不替换、单独的风格、大小和位置微调。还没定的图标不写进去。")
                }
                Section {
                    Toggle("带上原图（\(capture.icons.count) 个）", isOn: $includeOriginals)
                } footer: {
                    Text("带上原图，对方没抓过图也能直接打开、接着改，文件大一些。不带的话，对方要先导入自己的抓图 zip 或插件模板，再导入方案，按素材名对上。不会带上设备信息。")
                }
                Section {
                    Button { make() } label: { Label("生成方案文件", systemImage: "doc.zipper") }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let file {
                        Label(file.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button { save(file) } label: { Label(saved ? "已保存" : "保存到“文件”", systemImage: "folder") }
                        Button { shareFile = ShareFile(url: file) } label: { Label("分享（微信、隔空投送…）", systemImage: "square.and.arrow.up") }
                    }
                } footer: {
                    Text("对方在“逐个替换”页的菜单里选“导入别人的方案…”，或者在微信、“文件”里点这个 zip 用符号工坊打开。导入前会先备份对方自己的设置。")
                }
            }
            .navigationTitle("导出方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $shareFile) { ShareSheet(file: $0.url) }
            .alert("没有导出", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onChange(of: name) { _ in file = nil }
            .onChange(of: note) { _ in file = nil }
            .onChange(of: includeOriginals) { _ in file = nil }
        }
    }

    private func make() {
        saved = false
        do {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            file = try capture.exportScheme(name: name.trimmingCharacters(in: .whitespaces),
                                            note: trimmed.isEmpty ? nil : trimmed, includeOriginals: includeOriginals)
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(_ url: URL) {
        if !DocumentPicker.save(url, saved: { saved = true }) { shareFile = ShareFile(url: url) }
    }
}

struct SchemeImportSheet: View {
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    let package: SchemePackage
    let done: (String) -> Void
    @State private var options = SchemeImportOptions()
    @State private var errorMessage: String?

    var body: some View {
        let scheme = package.scheme
        let summary = capture.schemeSummary(package)
        let carried = package.icons.count
        return NavigationStack {
            List {
                Section {
                    LabeledContent("方案名", value: scheme.name)
                    if let note = scheme.note { Text(note).font(.callout).foregroundStyle(.secondary) }
                    if let wechat = scheme.wechat { LabeledContent("原图的微信版本", value: wechat) }
                    LabeledContent("生成时间", value: scheme.generated.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("替换 / 不替换", value: "\(scheme.replacedCount) / \(scheme.keptCount) 个")
                    LabeledContent("原图", value: carried > 0 ? "带了 \(carried) 个" : "没带")
                } header: {
                    Text("方案")
                }
                if capture.project == nil {
                    Section {
                        Text(carried > 0
                             ? "会用方案带的原图新建项目，设置和全局风格都照方案来，导入后可以接着改。"
                             : "这个方案没带原图。先导入抓图 zip 或插件模板，再导入这个方案。")
                    }
                } else {
                    Section {
                        LabeledContent("我还没定、会用方案设置的", value: "\(summary.fills) 个")
                        LabeledContent("两边一样的", value: "\(summary.same) 个")
                        LabeledContent("我已经定了、和方案不一样的", value: "\(summary.conflicts) 个")
                        if summary.conflicts > 0 {
                            Picker("这些图标", selection: $options.overwrite) {
                                Text("保留我的").tag(false)
                                Text("用方案的").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        if summary.newIcons > 0 {
                            Toggle("补上方案里有、我没有的 \(summary.newIcons) 个素材", isOn: $options.addIcons)
                        }
                        if summary.unknown > 0 {
                            Text("另有 \(summary.unknown) 个设置对应的素材我这里没有，方案也没带原图，会跳过。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("和我的项目比")
                    }
                }
                Section {
                    Toggle("用方案的全局风格", isOn: $options.useGlobal)
                } footer: {
                    Text("全局风格包括配色、粗细、渲染模式和尺寸统一，跟随全局的图标会照方案的样子画。关掉就保留我现在的全局风格。")
                }
                Section {
                    Button { apply() } label: { Label("导入方案", systemImage: "square.and.arrow.down") }
                        .disabled(capture.project == nil && carried == 0)
                } footer: {
                    Text("导入前会自动备份我现在的设置和全局风格，导错了可以在菜单“恢复替换设置”里找回。")
                }
            }
            .navigationTitle("导入方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("没有导入", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func apply() {
        do {
            let result = try capture.importScheme(package, options: options)
            var text = "已导入方案：\(result.applied) 个图标的设置"
            if result.addedIcons > 0 { text += "，新增 \(result.addedIcons) 个素材" }
            if result.skipped > 0 { text += "，跳过 \(result.skipped) 个" }
            done(text)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
