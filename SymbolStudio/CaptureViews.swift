import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lists every icon from an imported capture and lets the user pick a
/// replacement for each one, then exports them under WeChat's resource names.
@MainActor
struct CaptureView: View {
    @EnvironmentObject private var capture: CaptureStore
    /// A capture zip handed to the app with "Open in".
    @Binding var openedZip: URL?
    @State private var busy = false
    @State private var pendingImport: Data?
    @State private var askMerge = false
    @State private var filter = CaptureStore.Filter.all
    @State private var query = ""
    @State private var sheet: CaptureSheet?
    @State private var confirmRemove = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if capture.project == nil { emptyState } else { iconList }
            }
            .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .navigationTitle("逐个替换")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { pickZip() } label: { Label("导入抓图 zip…", systemImage: "square.and.arrow.down") }
                        if capture.project != nil {
                            Button { path.append(CaptureRoute.compare) } label: { Label("原图对比", systemImage: "rectangle.split.2x1") }
                            Button { sheet = .global } label: { Label("全局风格…", systemImage: "paintbrush") }
                            Button { sheet = .export } label: { Label("导出替换图标…", systemImage: "shippingbox") }
                            Button(role: .destructive) { confirmRemove = true } label: { Label("删除项目", systemImage: "trash") }
                        }
                        Button { sheet = .backups } label: { Label("恢复替换设置…", systemImage: "clock.arrow.circlepath") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationDestination(for: String.self) { name in
                CaptureDetailView(startName: name, names: visibleIcons.map(\.name))
            }
            .navigationDestination(for: CaptureRoute.self) { route in
                switch route {
                case .compare: CaptureCompareView()
                case .detail(let name, let names): CaptureDetailView(startName: name, names: names)
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .global: GlobalStyleSheet { message in showToast(message) }
            case .export: CaptureExportSheet()
            case .backups: BackupSheet { count in showToast("已恢复 \(count) 个图标的设置") }
            }
        }
        .confirmationDialog("已经有一个项目了", isPresented: $askMerge, titleVisibility: .visible) {
            Button("合并（推荐）") { runImport(merge: true) }
            Button("清空后重新导入", role: .destructive) { runImport(merge: false) }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: {
            Text("合并：新抓到的图标补进来，已经做过替换或标了不替换的图标一个都不动，连原图和位置也不改；新版原图有变化的会单独标出来，由你决定用不用。\n清空：项目重新开始。两种都会先自动备份替换设置，可在菜单“恢复替换设置”里找回。")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if busy {
                ProgressView("正在导入…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
        .task(id: openedZip) {
            guard let url = openedZip else { return }
            openedZip = nil
            receive(url)
        }
    }

    // MARK: Content

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.5, green: 0.35, blue: 0.94), Color(red: 0.17, green: 0.71, blue: 1)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("导入抓到的微信图标").font(.title3.weight(.semibold))
            Text("选抓图工具或替换插件导出的 zip（里面有 manifest.json）。导入后每个素材都会列出来：先在“全局风格”里定好整套的粗细、模式和配色，再一个一个挑符号；个别想单独处理的再单独调。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { pickZip() } label: { Label("导入抓图 zip…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
            Text("也可以在“文件”或聊天 App 里点 zip，选“用其他应用打开”→ 符号工坊。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = capture.loadError { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(28)
    }

    private var iconList: some View {
        List {
            Section { CaptureSummary(sheet: $sheet) { path.append(CaptureRoute.compare) } }
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(CaptureStore.Filter.allCases) { item in
                        Text(filterTitle(item)).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }
            ForEach(CaptureIcon.Kind.allCases, id: \.self) { kind in
                let rows = visibleIcons.filter { $0.kind == kind }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { icon in
                            NavigationLink(value: icon.name) { CaptureRow(icon: icon) }
                        }
                    } header: {
                        Text("\(kind.title)（\(rows.count)）")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索素材名或说明")
        .confirmationDialog("删除这个项目？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("删除", role: .destructive) { capture.removeProject() }
        } message: {
            Text("导入的原图会删除。替换设置会先自动备份，重新导入后可在菜单“恢复替换设置”里找回。")
        }
    }

    private func filterTitle(_ item: CaptureStore.Filter) -> String {
        let count = capture.icons.filter { capture.matches($0, item) }.count
        return "\(item.title)（\(count)）"
    }

    private var visibleIcons: [CaptureIcon] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return capture.icons.filter { icon in
            if !capture.matches(icon, filter) { return false }
            if text.isEmpty { return true }
            return icon.name.lowercased().contains(text) || (capture.title(for: icon)?.lowercased().contains(text) ?? false)
        }
    }

    // MARK: Import

    private func pickZip() {
        if !DocumentPicker.open([.zip, .data], picked: { receive($0) }) {
            errorMessage = "打不开文件选择器。"
        }
    }

    private func receive(_ url: URL) {
        do {
            let data = try PlanFile.read(url)
            pendingImport = data
            if capture.project != nil { askMerge = true } else { runImport(merge: false) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func runImport(merge: Bool) {
        guard let data = pendingImport else { return }
        pendingImport = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await capture.importCapture(data, merge: merge)
                var text = (result.fromTemplate ? "从插件模板导入：新增 " : "新增 ") + "\(result.added) 个素材"
                if result.updated > 0 {
                    text += result.fromTemplate ? "，已有的 \(result.updated) 个补上了插件需要的格式和尺寸" : "，已有的 \(result.updated) 个只补了尺寸和颜色"
                }
                if result.changedKept > 0 { text += "，\(result.changedKept) 个已替换的在新版里原图有变化（没改，可筛选查看）" }
                if !result.skipped.isEmpty { text += "，\(result.skipped.count) 个没读出来" }
                showToast(text)
                if merge && result.added > 0 { filter = .new }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(2, Double(text.count) / 12) * 1_000_000_000))
            if toast == text { toast = nil }
        }
    }
}

enum CaptureSheet: String, Identifiable {
    case global, export, backups
    var id: String { rawValue }
}

enum CaptureRoute: Hashable {
    case compare
    /// An icon's page, stepping through `names`.
    case detail(name: String, names: [String])
}

private struct CaptureSummary: View {
    @EnvironmentObject private var capture: CaptureStore
    @Binding var sheet: CaptureSheet?
    let compare: () -> Void

    var body: some View {
        let counts = Dictionary(grouping: capture.icons, by: { capture.status(of: $0) }).mapValues(\.count)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(capture.icons.count) 个素材").font(.headline)
            if let project = capture.project {
                Text([project.appVersion.map { "微信 " + $0 }, project.device].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if project.history.count > 1 {
                    let steps = project.history.map { "\($0.version ?? "?")（+\($0.added)）" }.joined(separator: " → ")
                    Text("导入 \(project.history.count) 次：\(steps)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                CountLabel(title: "已替换", value: counts[.replaced] ?? 0, color: .green)
                CountLabel(title: "不替换", value: counts[.kept] ?? 0, color: .gray)
                CountLabel(title: "待定", value: counts[.pending] ?? 0, color: .orange)
                CountLabel(title: "装饰", value: counts[.decorative] ?? 0, color: .secondary)
            }
        }
        .padding(.vertical, 4)
        Button { sheet = .global } label: {
            Label("全局风格…（跟随 \(capture.styleCounts.global) 个，单独设置 \(capture.styleCounts.own) 个）", systemImage: "paintbrush")
        }
        Button(action: compare) { Label("原图对比（和微信原图放在一起看）", systemImage: "rectangle.split.2x1") }
        Button { sheet = .export } label: { Label("导出替换图标…", systemImage: "shippingbox") }
            .disabled((counts[.replaced] ?? 0) == 0)
    }
}

private struct CountLabel: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct CaptureRow: View {
    @EnvironmentObject private var capture: CaptureStore
    let icon: CaptureIcon

    var body: some View {
        HStack(spacing: 10) {
            OriginalThumb(icon: icon, side: 40)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            if let choice = capture.choices[icon.name], choice.replace {
                ExactReplacementThumb(icon: icon, choice: choice, side: 40)
            } else {
                ReplacementThumb(choice: capture.choices[icon.name], side: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(icon.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    if capture.isNew(icon) { RowTag(text: "新", color: .blue) }
                    if icon.update != nil { RowTag(text: "原图有变化", color: .orange) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    private var detail: String {
        var parts: [String] = []
        if let title = capture.title(for: icon) { parts.append(title) }
        parts.append(icon.sizeText)
        if let choice = capture.choices[icon.name], choice.replace { parts.append(choice.symbol) }
        return parts.joined(separator: " · ")
    }
}

private struct RowTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

struct OriginalThumb: View {
    @EnvironmentObject private var capture: CaptureStore
    let icon: CaptureIcon
    var side: CGFloat
    var dark: Bool? = nil
    var outline = false

    var body: some View {
        let dark = self.dark ?? icon.prefersDarkTile
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(dark ? Color(white: 0.2) : Color(white: 0.94))
            Group {
                if let image = capture.image(for: icon) {
                    Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
                if outline { CanvasOutline(canvas: icon.canvas, dark: dark) }
            }
            .padding(side * 0.12)
        }
        .frame(width: side, height: side)
    }
}

/// The replacement exactly as exported, framed like `OriginalThumb`: the
/// two show the same canvas at the same scale, so sizes compare directly.
struct ExactReplacementThumb: View {
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.displayScale) private var displayScale
    let icon: CaptureIcon
    let choice: IconChoice
    var side: CGFloat
    var dark: Bool? = nil
    var outline = false
    /// The original drawn faintly underneath.
    var overlay = false
    @State private var image: UIImage?

    var body: some View {
        let dark = self.dark ?? icon.prefersDarkTile
        let ink = icon.inkBox.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "-"
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(dark ? Color(white: 0.2) : Color(white: 0.94))
            Group {
                if overlay, let original = capture.image(for: icon) {
                    Image(uiImage: original).resizable().interpolation(.high).aspectRatio(contentMode: .fit).opacity(0.35)
                }
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .opacity(overlay ? 0.8 : 1)
                }
                if outline { CanvasOutline(canvas: icon.canvas, dark: dark) }
            }
            .padding(side * 0.12)
        }
        .frame(width: side, height: side)
        .task(id: "\(icon.name)|\(choice.hashValue)|\(capture.global.hashValue)|\(icon.canvas.width)x\(icon.canvas.height)|\(ink)") {
            // Sliders change the global style many times a second; draw once they pause.
            if image != nil { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            image = capture.replacementPreview(for: icon, choice: choice, side: side, displayScale: displayScale)
        }
    }
}

/// Every WeChat original next to its SF Symbol replacement, both on the
/// original's canvas exactly as exported, with the sizing controls at hand.
struct CaptureCompareView: View {
    @EnvironmentObject private var capture: CaptureStore
    @State private var scope = Scope.replaced
    @State private var overlay = false
    @State private var dark = false

    enum Scope: String, CaseIterable, Identifiable {
        case replaced, suggested
        var id: String { rawValue }
        var title: String { self == .replaced ? "已替换的" : "加上待定的（推荐符号）" }
    }

    private struct Item: Identifiable {
        let icon: CaptureIcon
        let choice: IconChoice
        var id: String { icon.name }
    }

    /// Replaced icons; with `suggested` also undecided ones that have a
    /// suggested symbol, drawn as they would be if replaced now.
    private var items: [Item] {
        capture.icons.compactMap { icon in
            if let choice = capture.choices[icon.name] { return choice.replace ? Item(icon: icon, choice: choice) : nil }
            guard scope == .suggested, !capture.isDecorative(icon), !capture.symbols(for: icon).isEmpty else { return nil }
            var choice = capture.choice(for: icon)
            choice.replace = true
            return Item(icon: icon, choice: choice)
        }
    }

    var body: some View {
        let items = self.items
        let names = items.map(\.icon.name)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                if items.isEmpty {
                    Text(scope == .replaced ? "还没有设为替换的图标。选上面的“加上待定的”，先看推荐符号和原图的对比。" : "没有可对比的图标。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: CaptureRoute.detail(name: item.icon.name, names: names)) {
                            VStack(spacing: 4) {
                                HStack(spacing: 6) {
                                    OriginalThumb(icon: item.icon, side: 70, dark: dark ? true : nil, outline: true)
                                    ExactReplacementThumb(icon: item.icon, choice: item.choice, side: 70,
                                                          dark: dark ? true : nil, outline: true, overlay: overlay)
                                }
                                Text(item.icon.name).font(.system(size: 10)).lineLimit(1)
                                Text("\(item.choice.symbol) · \(item.icon.sizeText)")
                                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("原图对比")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("范围", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            SizingControls()
            HStack(spacing: 10) {
                Toggle(isOn: $overlay) { Label("叠加原图", systemImage: "square.on.square.dashed") }
                Toggle(isOn: $dark) { Label("深底", systemImage: "circle.lefthalf.filled") }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            Text("每对左边是微信原图，右边是导出的替换图：画布一样大、比例一样，虚线是画布边界。“叠加原图”把原图半透明垫在替换图下面。尺寸统一的设置和全局风格里是同一个，改了所有图标一起变；点一对进去可以换符号，或者单独微调大小和位置。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The global sizing mode and canvas share, on the global style sheet and the comparison page.
struct SizingControls: View {
    @EnvironmentObject private var capture: CaptureStore

    var body: some View {
        Picker("尺寸统一", selection: Binding(get: { capture.global.sizeMode }, set: { mode in
            var style = capture.global
            style.sizeMode = mode
            capture.setGlobal(style)
        })) {
            ForEach(IconSizing.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if capture.global.sizeMode != .original {
            LabeledContent("占画布 \(Int((capture.global.share * 100).rounded()))%") {
                Slider(value: Binding(get: { capture.global.share }, set: { value in
                    var style = capture.global
                    style.share = value
                    capture.setGlobal(style)
                }), in: 0.5...1, step: 0.01)
                .frame(maxWidth: 190)
            }
            if let original = capture.originalShare {
                Button("按原图的平均大小（\(Int((original * 100).rounded()))%）") {
                    var style = capture.global
                    style.share = original
                    capture.setGlobal(style)
                }
            }
        }
    }
}

struct ReplacementThumb: View {
    let choice: IconChoice?
    /// The look to draw with when it is not the choice's own (global style).
    var look: IconLook? = nil
    var side: CGFloat
    var dark = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(dark ? Color(white: 0.12) : Color(white: 0.985))
                .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).stroke(.gray.opacity(0.2), lineWidth: 1))
            if let choice, choice.replace {
                LookSymbol(symbol: choice.symbol, look: look ?? choice.look, side: side)
            } else if choice != nil {
                Text("原图").font(.system(size: side * 0.26)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "questionmark").font(.system(size: side * 0.3)).foregroundStyle(.quaternary)
            }
        }
        .frame(width: side, height: side)
    }
}

/// A symbol drawn with a look, sized to sit inside a square tile.
struct LookSymbol: View {
    let symbol: String
    let look: IconLook
    let side: CGFloat

    var body: some View {
        let scale = min(max(look.size, 0.5), 1.4)
        let size = Double(side) * (look.badge == nil ? 0.5 : 0.74) * scale
        StyledSymbol(name: symbol, style: look.style(pointSize: size), pointSize: size)
    }
}

// MARK: - Detail

@MainActor
struct CaptureDetailView: View {
    @EnvironmentObject private var capture: CaptureStore
    let names: [String]
    @Environment(\.displayScale) private var displayScale
    @State private var name: String
    @State private var detailSheet: DetailSheet?
    @State private var rendered: UIImage?
    @State private var renderedSVG: String?
    @State private var darkTiles: Bool?
    @State private var overlay = false

    private enum DetailSheet: Identifiable {
        case picker
        case global
        case zoom(String)

        var id: String {
            switch self {
            case .picker: return "picker"
            case .global: return "global"
            case .zoom: return "zoom"
            }
        }
    }

    init(startName: String, names: [String]) {
        self.names = names
        _name = State(initialValue: startName)
    }

    private var icon: CaptureIcon? { capture.icons.first { $0.name == name } }
    private var position: Int? { names.firstIndex(of: name) }

    var body: some View {
        Group {
            if let icon {
                detail(icon)
            } else {
                Text("找不到这个素材").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled((position ?? 0) <= 0)
                Spacer()
                Text(position.map { "\($0 + 1) / \(names.count)" } ?? "").font(.caption).monospacedDigit()
                Spacer()
                Button("下一个待定") { nextPending() }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled((position ?? names.count) >= names.count - 1)
            }
        }
    }

    private func detail(_ icon: CaptureIcon) -> some View {
        let choice = capture.choice(for: icon)
        let look = capture.effectiveLook(for: icon, choice: choice)
        let saved = capture.choices[icon.name]
        return List {
            if let update = icon.update { updateSection(icon, update) }
            Section {
                compare(icon, choice: saved)
                actualSize(icon, choice: saved)
            } footer: {
                Text("右边就是导出的样子：和原图一样大的画布，大小和位置按全局风格里的“尺寸统一”，再加下面的微调。打开“叠加原图”能看出差在哪，虚线是画布边界。")
            }
            Section {
                Picker("处理方式", selection: decisionBinding(icon)) {
                    Text("待定").tag(Decision.pending)
                    Text("替换").tag(Decision.replace)
                    Text("不替换").tag(Decision.keep)
                }
                .pickerStyle(.segmented)
            }
            Section {
                symbolStrip(icon, choice: choice, look: look)
            } header: {
                Text("符号")
            } footer: {
                Text("前几个是按这个素材的用途挑的。点放大镜按分类找，也可以直接搜索（中英文都行）。")
            }
            Section {
                Toggle("跟随全局风格", isOn: followBinding(icon))
                Button { detailSheet = .global } label: { Label("编辑全局风格…", systemImage: "paintbrush") }
            } footer: {
                Text(choice.usesGlobal
                     ? "这个图标用全局风格画，全局风格一改它就跟着变。点下面的风格或改“单独设置”，它就只用自己的风格。"
                     : "这个图标单独设置了风格，改全局风格不会影响它。打开开关可以改回跟随全局。")
            }
            Section {
                presetGrid(icon, choice: choice)
            } header: {
                Text("单独设置：风格")
            }
            Section {
                LookEditor(look: lookBinding(icon))
            } header: {
                Text("单独设置：自定义")
            } footer: {
                Text("在这里改动只影响这一个图标。渐变：点“加渐变”后选结束色，角度对所有层生效。")
            }
            if saved?.replace == true { adjustSection(icon, choice: choice, look: look) }
            Section {
                info(icon)
            } header: {
                Text("素材信息")
            }
        }
        .sheet(item: $detailSheet) { sheet in
            switch sheet {
            case .picker: SymbolPickerSheet(look: look) { symbol in update(icon) { $0.symbol = symbol } }
            case .global: GlobalStyleSheet()
            case .zoom(let svg): SVGZoomSheet(svg: svg, title: icon.name, dark: darkTiles ?? icon.prefersDarkTile)
            }
        }
        .task(id: RenderKey(name: icon.name, choice: saved, look: saved.map { capture.effectiveLook(for: icon, choice: $0) },
                            global: capture.global)) {
            // Sliders change the choice many times a second; draw once they pause.
            if rendered != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard !Task.isCancelled else { return }
            render(icon, choice: saved)
        }
    }

    // MARK: Sections

    private func updateSection(_ icon: CaptureIcon, _ update: CaptureUpdate) -> some View {
        Section {
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    OriginalThumb(icon: icon, side: 64)
                    Text("现在用的 \(SVGWriter.number(icon.canvas.width))×\(SVGWriter.number(icon.canvas.height))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(icon.prefersDarkTile ? Color(white: 0.2) : Color(white: 0.94))
                        if let image = capture.updateImage(for: icon) {
                            Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(8)
                        }
                    }
                    .frame(width: 64, height: 64)
                    Text("\(update.version.map { "微信 " + $0 } ?? "新抓的") \(SVGWriter.number(update.canvas.width))×\(SVGWriter.number(update.canvas.height))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            Button("改用新版原图") { capture.adoptUpdate(for: icon) }
            Button("保持现在的", role: .destructive) { capture.dismissUpdate(for: icon) }
        } header: {
            Text("新版原图有变化")
        } footer: {
            Text("新抓到的这个素材大小或位置和之前不一样。你已经给它做过替换，所以没有自动改。改用新版原图后，替换图会按新的画布和位置导出，选的符号和配色不变。")
        }
    }

    private func compare(_ icon: CaptureIcon, choice: IconChoice?) -> some View {
        let dark = darkTiles ?? icon.prefersDarkTile
        return VStack(spacing: 10) {
            HStack(spacing: 14) {
                VStack(spacing: 6) {
                    OriginalThumb(icon: icon, side: 120, dark: dark)
                    Text("原图").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(dark ? Color(white: 0.2) : Color(white: 0.94))
                        Group {
                            if let rendered, choice?.replace == true {
                                if overlay, let image = capture.image(for: icon) {
                                    Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).opacity(0.35)
                                }
                                Image(uiImage: rendered).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                    .opacity(overlay ? 0.75 : 1)
                            } else if let image = capture.image(for: icon) {
                                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).opacity(0.35)
                            }
                            if overlay { CanvasOutline(canvas: icon.canvas, dark: dark) }
                        }
                        .padding(14)
                    }
                    .frame(width: 120, height: 120)
                    .contentShape(Rectangle())
                    .onTapGesture { if let renderedSVG, choice?.replace == true { detailSheet = .zoom(renderedSVG) } }
                    Text(choice?.replace == true ? "替换后 · 点一下放大" : "未替换").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Picker("底色", selection: Binding(get: { dark }, set: { darkTiles = $0 })) {
                    Text("浅底").tag(false)
                    Text("深底").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                Toggle(isOn: $overlay) { Label("叠加原图", systemImage: "square.on.square.dashed") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(choice?.replace != true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// The icon's own nudge on top of the global sizing.
    private func adjustSection(_ icon: CaptureIcon, choice: IconChoice, look: IconLook) -> some View {
        let geometry = capture.geometry(for: icon, choice: choice, look: look)
        let adjust = choice.adjust ?? IconAdjust()
        let slim: String = geometry.sizing != capture.global.sizeMode ? "这个素材的画布是窄长的（箭头、圆点一类），所以按原图内容的位置放。" : ""
        return Section {
            LabeledContent("大小 \(Int((adjust.scale * 100).rounded()))%") {
                Slider(value: adjustBinding(icon, \.scale), in: 0.5...1.5, step: 0.01).frame(maxWidth: 190)
            }
            LabeledContent("左右 \(Self.signed(adjust.dx))") {
                Slider(value: adjustBinding(icon, \.dx), in: -0.25...0.25, step: 0.005).frame(maxWidth: 190)
            }
            LabeledContent("上下 \(Self.signed(adjust.dy))") {
                Slider(value: adjustBinding(icon, \.dy), in: -0.25...0.25, step: 0.005).frame(maxWidth: 190)
            }
            Button("复位") { update(icon) { $0.adjust = nil } }
                .disabled(adjust.isIdentity)
            Button { detailSheet = .global } label: {
                Label("尺寸统一：\(capture.global.sizeMode.title)…", systemImage: "square.dashed")
            }
        } header: {
            Text("大小和位置（只影响这个图标）")
        } footer: {
            Text(slim + "在全局“尺寸统一”的基础上微调，图标仍然跟随全局风格。位置按画布宽高的百分比移动。")
        }
    }

    private static func signed(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    private func adjustBinding(_ icon: CaptureIcon, _ key: WritableKeyPath<IconAdjust, Double>) -> Binding<Double> {
        Binding(get: { (capture.choices[icon.name]?.adjust ?? IconAdjust())[keyPath: key] }, set: { value in
            update(icon) { choice in
                var adjust = choice.adjust ?? IconAdjust()
                adjust[keyPath: key] = value
                choice.adjust = adjust.isIdentity ? nil : adjust
            }
        })
    }

    /// Original and replacement at their real size in points.
    private func actualSize(_ icon: CaptureIcon, choice: IconChoice?) -> some View {
        let width = min(icon.canvas.width, 120), height = min(icon.canvas.height, 120)
        return HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 16) {
                    if let image = capture.image(for: icon) {
                        Image(uiImage: image).resizable().interpolation(.high).frame(width: width, height: height)
                    }
                    if let rendered, choice?.replace == true {
                        Image(uiImage: rendered).resizable().interpolation(.high).frame(width: width, height: height)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
                .background(dark ? Color(white: 0.1) : Color.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.gray.opacity(0.2), lineWidth: 1))
        .accessibilityLabel("实际大小对比")
    }

    private func symbolStrip(_ icon: CaptureIcon, choice: IconChoice, look: IconLook) -> some View {
        var candidates = capture.symbols(for: icon)
        if !candidates.contains(choice.symbol), UIImage(systemName: choice.symbol) != nil { candidates.insert(choice.symbol, at: 0) }
        let selected = capture.choices[icon.name]?.replace == true ? choice.symbol : nil
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(candidates, id: \.self) { symbol in
                    Button { update(icon) { $0.symbol = symbol } } label: {
                        OptionTile(selected: symbol == selected, caption: symbol) {
                            LookSymbol(symbol: symbol, look: look, side: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button { detailSheet = .picker } label: {
                    OptionTile(selected: false, caption: "更多符号") {
                        Image(systemName: "square.grid.2x2").font(.title2).foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private func presetGrid(_ icon: CaptureIcon, choice: IconChoice) -> some View {
        let selected = capture.choices[icon.name]?.replace == true && !choice.usesGlobal ? choice.presetID : nil
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 10)], spacing: 12) {
            ForEach(LookPreset.all) { preset in
                Button {
                    update(icon, ownStyle: true) { $0.look = preset.look(for: icon); $0.presetID = preset.id }
                } label: {
                    OptionTile(selected: preset.id == selected, caption: preset.title) {
                        LookSymbol(symbol: choice.symbol, look: preset.look(for: icon), side: 56)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func info(_ icon: CaptureIcon) -> some View {
        if let title = capture.title(for: icon) { LabeledContent("用途", value: title) }
        LabeledContent("类型", value: icon.kind.title)
        if let plugin = icon.plugin {
            LabeledContent("插件模板", value: plugin.formats.joined(separator: " + ") + (plugin.hasDark ? "（含深色）" : ""))
            if let inApp = plugin.inApp { LabeledContent("App 内文件", value: inApp) }
        }
        LabeledContent("尺寸（点）", value: icon.sizeText)
        if !icon.colors.isEmpty {
            LabeledContent("微信画的颜色") {
                HStack(spacing: 6) {
                    ForEach(icon.colors, id: \.self) { hex in
                        Circle().fill(RGBA(hex: hex)?.color ?? .clear)
                            .overlay(Circle().stroke(.gray.opacity(0.4), lineWidth: 1))
                            .frame(width: 16, height: 16)
                    }
                }
            }
        }
        if !icon.angles.isEmpty {
            LabeledContent("微信旋转", value: icon.angles.map { "\(Int($0))°" }.joined(separator: "、"))
            Text("微信画这个素材时会旋转，替换图要按旋转前的方向做。抓到的原图是旋转后的样子。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if icon.kind == .svg {
            Text("这是微信上色的 SVG：微信画的时候会传一个颜色。替换成多色图后，颜色能不能保留取决于覆盖插件是否让微信再上色。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        LabeledContent("抓到次数", value: "\(icon.captures)")
    }

    // MARK: State

    private enum Decision: Hashable { case pending, replace, keep }

    private func decisionBinding(_ icon: CaptureIcon) -> Binding<Decision> {
        Binding(get: {
            guard let saved = capture.choices[icon.name] else { return .pending }
            return saved.replace ? .replace : .keep
        }, set: { decision in
            switch decision {
            case .pending: capture.setChoice(nil, for: icon)
            case .replace: update(icon) { _ in }
            case .keep:
                var choice = capture.choice(for: icon)
                choice.replace = false
                choice.manual = true
                capture.setChoice(choice, for: icon)
            }
        })
    }

    /// Editing starts from what the icon looks like now, global style included.
    private func lookBinding(_ icon: CaptureIcon) -> Binding<IconLook> {
        Binding(get: {
            let choice = capture.choice(for: icon)
            return capture.effectiveLook(for: icon, choice: choice)
        }, set: { look in
            update(icon, ownStyle: true) { $0.look = look; $0.presetID = nil }
        })
    }

    private func followBinding(_ icon: CaptureIcon) -> Binding<Bool> {
        Binding(get: { capture.choice(for: icon).usesGlobal }, set: { follow in
            var choice = capture.choice(for: icon)
            if !follow {
                // Start the icon's own look from what it shows now.
                choice.look = capture.effectiveLook(for: icon, choice: choice)
                choice.presetID = nil
            }
            choice.followsGlobal = follow
            choice.replace = true
            choice.manual = true
            capture.setChoice(choice, for: icon)
        })
    }

    /// Changes the icon's choice and marks it as replaced by hand. With
    /// `ownStyle` the icon stops following the global style.
    private func update(_ icon: CaptureIcon, ownStyle: Bool = false, _ change: (inout IconChoice) -> Void) {
        var choice = capture.choice(for: icon)
        change(&choice)
        choice.replace = true
        choice.manual = true
        if ownStyle { choice.followsGlobal = false }
        capture.setChoice(choice, for: icon)
    }

    private func step(_ delta: Int) {
        guard let position else { return }
        let next = position + delta
        guard names.indices.contains(next) else { return }
        name = names[next]
        rendered = nil
    }

    private func nextPending() {
        let start = (position ?? -1) + 1
        let order = Array(names[min(start, names.count)...]) + Array(names[..<min(start, names.count)])
        if let next = order.first(where: { candidate in
            capture.icons.first(where: { $0.name == candidate }).map { capture.status(of: $0) == .pending } ?? false
        }) {
            name = next
            rendered = nil
        }
    }

    private struct RenderKey: Hashable {
        let name: String
        let choice: IconChoice?
        let look: IconLook?
        let global: GlobalStyle
    }

    /// The replacement exactly as the export draws it.
    private func render(_ icon: CaptureIcon, choice: IconChoice?) {
        guard let choice, choice.replace, let output = capture.renderReplacement(for: icon, choice: choice) else {
            rendered = nil
            renderedSVG = nil
            return
        }
        // Enough pixels for the 120 pt tile on this screen.
        let scale = max(3, displayScale * 120 / max(icon.canvas.width, icon.canvas.height, 1))
        rendered = SymbolPipeline.rasterize(pdf: output.pdf, layout: output.layout, pixelScale: scale, background: nil)
            .flatMap { UIImage(data: $0, scale: scale) }
        renderedSVG = SVGWriter.svg(output.drawing, layout: output.layout, title: icon.name, background: nil)
    }
}

/// The exported SVG itself, pinch to zoom.
struct SVGZoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    let svg: String
    let title: String
    @State var dark: Bool

    var body: some View {
        NavigationStack {
            ZoomableSVGView(svg: svg)
                .background(dark ? Color(white: 0.12) : Color(white: 0.95))
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        Picker("底色", selection: $dark) {
                            Text("浅底").tag(false)
                            Text("深底").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        Text("这是导出的 SVG 文件本身，双指放大，边缘一直是平滑的。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// The canvas edge, dashed, fitted into the same space as an image of the canvas.
struct CanvasOutline: View {
    let canvas: CGSize
    var dark = false

    var body: some View {
        Rectangle()
            .stroke(dark ? Color.white.opacity(0.45) : Color.black.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .aspectRatio(canvas.width / max(canvas.height, 0.001), contentMode: .fit)
    }
}

struct OptionTile<Content: View>: View {
    let selected: Bool
    let caption: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.97))
                content()
            }
            .frame(width: 66, height: 66)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: selected ? 2.5 : 1))
            Text(caption).font(.system(size: 10)).lineLimit(1).frame(width: 70)
        }
    }
}

// MARK: - Custom look

struct LookEditor: View {
    @Binding var look: IconLook

    var body: some View {
        Picker("渲染模式", selection: $look.mode) {
            ForEach(RenderModeChoice.allCases) { Text($0.title).tag($0) }
        }
        ForEach(0..<look.layerCount, id: \.self) { index in
            FillRow(title: layerTitle(index), fill: fill(index))
        }
        if look.mode != .multicolor {
            LabeledContent("渐变角度") {
                Slider(value: angle, in: 0...360, step: 15).frame(maxWidth: 190)
            }
        }
        Picker("粗细", selection: $look.weight) {
            ForEach(WeightChoice.allCases) { Text($0.title).tag($0) }
        }
        if SymbolGradientSupport.isAvailable {
            Toggle("系统渐变渲染（iOS 26）", isOn: $look.gradientRendering)
        }
        Toggle("加底座（像 App 图标）", isOn: badgeOn)
        if look.badge != nil {
            Picker("底座形状", selection: badgeShape) {
                ForEach(BadgeShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            FillRow(title: "底座颜色", fill: badgeFill)
            LabeledContent("符号占比") {
                Slider(value: glyphScale, in: 0.3...0.8).frame(maxWidth: 190)
            }
        }
    }

    private func layerTitle(_ index: Int) -> String {
        switch look.mode {
        case .multicolor: return "强调色"
        case .palette: return "第 \(index + 1) 层"
        default: return "颜色"
        }
    }

    private func fill(_ index: Int) -> Binding<GradientFill> {
        Binding(get: {
            look.fills.indices.contains(index) ? look.fills[index] : (look.fills.last ?? GradientFill(solid: .black))
        }, set: { value in
            var fills = look.fills
            while fills.count <= index { fills.append(fills.last ?? value) }
            fills[index] = value
            look.fills = fills
        })
    }

    private var angle: Binding<Double> {
        Binding(get: { look.fills.first?.angle ?? 45 }, set: { value in
            look.fills = look.fills.map { var fill = $0; fill.angle = value; return fill }
            if var badge = look.badge {
                badge.fill.angle = value
                look.badge = badge
            }
        })
    }

    private var badgeOn: Binding<Bool> {
        Binding(get: { look.badge != nil }, set: { on in
            if on, look.badge == nil {
                let fill = look.fills.first ?? GradientFill(RGBA(red: 0.42, green: 0.36, blue: 1), RGBA(red: 0.75, green: 0.3, blue: 0.99))
                look.badge = SymbolBadge(shape: .squircle, fill: fill.isSolid ? GradientFill(fill.start, fill.start.shifted(), angle: fill.angle) : fill)
                look.fills = [GradientFill(solid: .white)]
                if look.mode == .multicolor || look.mode == .palette { look.mode = .hierarchical }
            } else if !on, let badge = look.badge {
                look.fills = [badge.fill]
                look.badge = nil
            }
        })
    }

    private var badgeShape: Binding<BadgeShape> {
        Binding(get: { look.badge?.shape ?? .squircle }, set: { look.badge?.shape = $0 })
    }

    private var badgeFill: Binding<GradientFill> {
        Binding(get: { look.badge?.fill ?? GradientFill(solid: .black) }, set: { look.badge?.fill = $0 })
    }

    private var glyphScale: Binding<Double> {
        Binding(get: { look.badge?.glyphScale ?? 0.5 }, set: { look.badge?.glyphScale = $0 })
    }
}

struct FillRow: View {
    let title: String
    @Binding var fill: GradientFill

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill.shapeStyle)
                .frame(width: 34, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.gray.opacity(0.3), lineWidth: 1))
            ColorPicker("起始色", selection: color(\.start)).labelsHidden()
            if !fill.isSolid {
                ColorPicker("结束色", selection: color(\.end)).labelsHidden()
            }
            Button(fill.isSolid ? "加渐变" : "纯色") {
                if fill.isSolid { fill.end = fill.start.shifted() } else { fill.end = fill.start }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func color(_ keyPath: WritableKeyPath<GradientFill, RGBA>) -> Binding<Color> {
        Binding(get: { fill[keyPath: keyPath].color }, set: { fill[keyPath: keyPath] = RGBA($0) })
    }
}

extension RGBA {
    /// A neighbor color for starting a gradient: hue turned a little, a bit lighter.
    func shifted() -> RGBA {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: self.alpha).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.08 { return RGBA(red: min(red + 0.3, 1), green: min(green + 0.3, 1), blue: min(blue + 0.3, 1), alpha: self.alpha) }
        let turned = (hue + 0.09).truncatingRemainder(dividingBy: 1)
        return RGBA(uiColor: UIColor(hue: turned, saturation: saturation, brightness: min(brightness + 0.12, 1), alpha: alpha))
    }
}

// MARK: - Sheets

/// Picks a symbol: the categories come first, each opening its symbols drawn
/// in the icon's current look. The search field searches every symbol.
struct SymbolPickerSheet: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let look: IconLook
    let picked: (String) -> Void
    @State private var query = ""

    private enum Page: Hashable {
        case favorites, recent, other
        case category(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.catalog == nil {
                    ProgressView("正在准备图标库…")
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    categoryList
                } else {
                    SymbolTileGrid(items: searchResults, look: look, pick: choose)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索全部符号，如 heart、相机")
            .navigationTitle("选择符号")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                SymbolCategoryPage(title: title(page), items: items(page), look: look, pick: choose)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private var categoryList: some View {
        List {
            let favorites = store.favorites.count
            let recent = store.recent.count
            if favorites > 0 || recent > 0 {
                Section {
                    if favorites > 0 { row(.favorites, "我的收藏", "star", favorites) }
                    if recent > 0 { row(.recent, "最近使用", "clock", recent) }
                }
            }
            Section {
                ForEach(store.catalog?.categories ?? []) { category in
                    row(.category(category.id), category.title, category.icon, category.count)
                }
                let other = store.catalog?.symbols.filter { $0.categories.isEmpty }.count ?? 0
                if other > 0 { row(.other, "未分类", "questionmark.square.dashed", other) }
            } header: {
                Text("分类")
            }
        }
    }

    private func row(_ page: Page, _ title: String, _ icon: String, _ count: Int) -> some View {
        NavigationLink(value: page) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ page: Page) -> String {
        switch page {
        case .favorites: return "我的收藏"
        case .recent: return "最近使用"
        case .other: return "未分类"
        case .category(let id): return store.catalog?.categories.first { $0.id == id }?.title ?? id
        }
    }

    private func items(_ page: Page) -> [SymbolItem] {
        let symbols = store.catalog?.symbols ?? []
        switch page {
        case .favorites: return store.favorites.sorted().compactMap { store.item(named: $0) }
        case .recent: return store.recent.compactMap { store.item(named: $0) }
        case .other: return symbols.filter { $0.categories.isEmpty }
        case .category(let id): return symbols.filter { $0.categories.contains(id) }
        }
    }

    private var searchResults: [SymbolItem] {
        guard let symbols = store.catalog?.symbols else { return [] }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return Array(symbols.filter { $0.searchableText.lowercased().contains(text) }.prefix(300))
    }

    private func choose(_ name: String) {
        store.recordRecent(name)
        picked(name)
        dismiss()
    }
}

/// One category's symbols, with a search limited to that category.
private struct SymbolCategoryPage: View {
    let title: String
    let items: [SymbolItem]
    let look: IconLook
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        SymbolTileGrid(items: filtered, look: look, pick: pick)
            .searchable(text: $query, prompt: "在“\(title)”里搜索")
            .navigationTitle("\(title)（\(items.count)）")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [SymbolItem] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? items : items.filter { $0.searchableText.lowercased().contains(text) }
    }
}

private struct SymbolTileGrid: View {
    let items: [SymbolItem]
    let look: IconLook
    let pick: (String) -> Void

    var body: some View {
        ScrollView {
            if items.isEmpty {
                Text("没有找到符号，换个关键词试试。").foregroundStyle(.secondary).padding(.top, 40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 10) {
                ForEach(items, id: \.name) { item in
                    Button { pick(item.name) } label: {
                        OptionTile(selected: false, caption: item.name) {
                            LookSymbol(symbol: item.name, look: look, side: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The look every icon gets unless it was styled on its own, with a live
/// preview of icons that follow it.
struct GlobalStyleSheet: View {
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    var done: (String) -> Void = { _ in }
    @State private var confirmReset = false
    @State private var confirmClearAdjust = false
    @State private var pairImages: [String: UIImage] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    preview
                } header: {
                    Text("预览")
                } footer: {
                    Text("这里是跟随全局风格的图标。改下面的设置，它们会一起变；单独设置过风格的图标不受影响。")
                }
                sizingSection
                Section {
                    presets
                } header: {
                    Text("从预设开始")
                } footer: {
                    Text("点一个预设，把它的模式、粗细和配色作为全局风格，再在下面细调。")
                }
                Section {
                    LookEditor(look: lookBinding)
                    Toggle("主色用微信原来的颜色", isOn: originalColorBinding)
                } header: {
                    Text("全局样式")
                } footer: {
                    Text("“主色用微信原来的颜色”打开后，警告图标保持红色、勾选保持绿色这类原有颜色，只换形状和其余配色；没有记录到颜色的图标用上面的主色。")
                }
                Section {
                    LabeledContent("跟随全局", value: "\(capture.styleCounts.global) 个")
                    LabeledContent("单独设置（不受影响）", value: "\(capture.styleCounts.own) 个")
                    Button {
                        let count = capture.fillPending()
                        done("已把 \(count) 个待定图标设为替换，跟随全局风格")
                        dismiss()
                    } label: {
                        Label("把待定的 \(capture.fillableIcons.count) 个都设为替换（用推荐符号）", systemImage: "checkmark.circle")
                    }
                    .disabled(capture.fillableIcons.isEmpty)
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label("把单独设置的也改回跟随全局…", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(capture.styleCounts.own == 0)
                } header: {
                    Text("范围")
                } footer: {
                    Text("待定的图标设为替换时用推荐的第一个符号；装饰类素材（阴影、背景、加载动画等）不会被设上。")
                }
            }
            .navigationTitle("全局风格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("把单独设置的图标改回跟随全局？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("改回跟随全局", role: .destructive) {
                    let count = capture.resetOwnStyles()
                    done("\(count) 个图标改回跟随全局风格")
                }
            } message: {
                Text("它们选的符号不变，只是风格改为全局风格。改之前会自动备份，可在“恢复替换设置”里找回。")
            }
            .confirmationDialog("清除单独调的大小和位置？", isPresented: $confirmClearAdjust, titleVisibility: .visible) {
                Button("全部按“尺寸统一”放", role: .destructive) {
                    let count = capture.resetAdjustments()
                    done("\(count) 个图标的大小和位置改回按“尺寸统一”")
                }
            } message: {
                Text("改之前会自动备份，可在“恢复替换设置”里找回。")
            }
        }
    }

    // MARK: Sizing

    private var sizingSection: some View {
        let style = capture.global
        return Section {
            SizingControls()
            pairs
            if capture.adjustedCount > 0 {
                Button(role: .destructive) { confirmClearAdjust = true } label: {
                    Label("清除 \(capture.adjustedCount) 个图标单独调的大小和位置…", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("尺寸统一")
        } footer: {
            Text(style.sizeMode.detail + "\n窄长的画布（箭头、圆点、横条）总是对齐原图内容。尺寸统一对所有替换图标生效，单独设置风格的也一样；图标详情里还能再单独微调大小和位置。上面每对图左边是原图，右边是导出的替换图，虚线是画布边界；全部图标的对比在“逐个替换”页的“原图对比”。")
        }
    }

    private struct PairKey: Hashable {
        let style: GlobalStyle
        let choices: [IconChoice]
    }

    private struct Pair: Identifiable {
        let icon: CaptureIcon
        let choice: IconChoice
        var id: String { icon.name }
    }

    /// The first replaced icons, or undecided ones when none is replaced yet.
    private var pairSamples: [Pair] {
        var result: [Pair] = []
        for icon in capture.icons where result.count < 8 {
            guard let choice = capture.choices[icon.name], choice.replace else { continue }
            result.append(Pair(icon: icon, choice: choice))
        }
        if result.isEmpty {
            for icon in capture.fillableIcons.prefix(8) {
                var choice = capture.choice(for: icon)
                choice.replace = true
                result.append(Pair(icon: icon, choice: choice))
            }
        }
        return result
    }

    private var pairs: some View {
        let samples = pairSamples
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
            ForEach(samples) { sample in
                let dark = sample.icon.prefersDarkTile
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        pairTile(capture.image(for: sample.icon), canvas: sample.icon.canvas, dark: dark)
                        pairTile(pairImages[sample.icon.name], canvas: sample.icon.canvas, dark: dark)
                    }
                    Text(sample.icon.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: PairKey(style: capture.global, choices: samples.map(\.choice))) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            var images: [String: UIImage] = [:]
            for sample in samples {
                images[sample.icon.name] = capture.replacementPreview(for: sample.icon, choice: sample.choice,
                                                                      side: 52, displayScale: displayScale)
                await Task.yield()
                if Task.isCancelled { return }
            }
            pairImages = images
        }
    }

    private func pairTile(_ image: UIImage?, canvas: CGSize, dark: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dark ? Color(white: 0.2) : Color(white: 0.94))
            Group {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
                CanvasOutline(canvas: canvas, dark: dark)
            }
            .padding(5)
        }
        .frame(width: 62, height: 62)
    }

    private struct Sample: Identifiable {
        let name: String
        let symbol: String
        let look: IconLook
        var id: String { name }
    }

    /// Up to twelve icons that follow the global style, or undecided ones
    /// with a suggested symbol when nothing follows it yet.
    private var samples: [Sample] {
        var result: [Sample] = []
        for icon in capture.icons where result.count < 12 {
            guard let choice = capture.choices[icon.name], choice.replace, choice.usesGlobal else { continue }
            result.append(Sample(name: icon.name, symbol: choice.symbol, look: capture.effectiveLook(for: icon, choice: choice)))
        }
        if result.isEmpty {
            for icon in capture.fillableIcons.prefix(12) {
                let choice = capture.choice(for: icon)
                result.append(Sample(name: icon.name, symbol: choice.symbol, look: capture.effectiveLook(for: icon, choice: choice)))
            }
        }
        return result
    }

    private var preview: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 10) {
            ForEach(samples) { sample in
                OptionTile(selected: false, caption: sample.name) {
                    LookSymbol(symbol: sample.symbol, look: sample.look, side: 56)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var presets: some View {
        let symbol = samples.first?.symbol ?? "heart.fill"
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(LookPreset.all) { preset in
                    Button {
                        var style = capture.global
                        style.look = preset.look(for: nil)
                        capture.setGlobal(style)
                    } label: {
                        OptionTile(selected: capture.global.look == preset.look(for: nil), caption: preset.title) {
                            LookSymbol(symbol: symbol, look: preset.look(for: nil), side: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var lookBinding: Binding<IconLook> {
        Binding(get: { capture.global.look }, set: { look in
            var style = capture.global
            style.look = look
            capture.setGlobal(style)
        })
    }

    private var originalColorBinding: Binding<Bool> {
        Binding(get: { capture.global.useOriginalColor }, set: { value in
            var style = capture.global
            style.useOriginalColor = value
            capture.setGlobal(style)
        })
    }
}

struct BackupSheet: View {
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    let done: (Int) -> Void
    @State private var backups: [CaptureBackup] = []
    @State private var selected: CaptureBackup?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if backups.isEmpty {
                    Text("还没有备份。导入、清空、删除项目和一键套用改动已有设置之前，都会自动备份一次。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(backups) { backup in
                        Button { selected = backup } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.primary)
                                Text("\(backup.reason) · \(backup.count) 个图标").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    if !backups.isEmpty {
                        Text("恢复会把备份里每个图标的设置放回去，备份里没有的图标保持现在的样子。恢复前也会先备份一次，恢复错了还能再恢复回来。")
                    }
                }
            }
            .navigationTitle("恢复替换设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("恢复这份备份？", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                                titleVisibility: .visible, presenting: selected) { backup in
                Button("恢复 \(backup.count) 个图标的设置") {
                    do {
                        let count = try capture.restore(backup)
                        done(count)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                Button("取消", role: .cancel) { selected = nil }
            } message: { backup in
                Text("\(backup.reason)（\(backup.date.formatted(date: .numeric, time: .shortened))）")
            }
            .alert("恢复失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onAppear { backups = capture.backups() }
        }
    }
}

struct CaptureExportSheet: View {
    enum Target: String, CaseIterable, Identifiable {
        case plugin, generic
        var id: String { rawValue }
        var title: String { self == .plugin ? "替换插件包" : "通用（PNG + SVG）" }
    }

    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var target = Target.plugin
    @State private var scales = [3]
    @State private var formats = BatchFormats.both
    @State private var svgScale: CGFloat = 1
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var summary: BatchSummary?
    @State private var shareFile: ShareFile?
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("导出给", selection: $target) {
                        ForEach(Target.allCases) { Text($0.title).tag($0) }
                    }
                    if target == .generic {
                        Picker("倍率", selection: $scales) {
                            Text("@3x").tag([3])
                            Text("@2x").tag([2])
                            Text("@2x + @3x").tag([2, 3])
                        }
                        Picker("格式", selection: $formats) {
                            Text("PNG + SVG").tag(BatchFormats.both)
                            Text("仅 PNG").tag(BatchFormats.png)
                            Text("仅 SVG").tag(BatchFormats.svg)
                        }
                        Picker("SVG 标注尺寸", selection: $svgScale) {
                            Text("和原图一样").tag(CGFloat(1))
                            Text("放大 10 倍").tag(CGFloat(10))
                        }
                    }
                } footer: {
                    if target == .plugin {
                        Text("和替换插件的模板一样：位图素材写成 png/名字@3x.png（模板里有深色版的再写一份到 png-dark/），SVG 素材写成 svg/名字.svg，manifest.json 里每个文件一条，带 inApp。只包含要替换的图标，可以直接在插件的“图标替换”里导入。画布和原图一样大，大小和位置按全局风格里的“尺寸统一”和每个图标的微调。")
                    } else {
                        Text("文件按微信素材名命名：name@3x.png，SVG 在 svg/ 文件夹。画布和原图一样大，大小和位置按全局风格里的“尺寸统一”和每个图标的微调。zip 里还有 plan.json，可以在“批量导出”页重新导入。\nSVG 是矢量，内容不受“标注尺寸”影响；只是“文件”这类预览会按标注尺寸先画成图片，24×24 的图标放大看就糊。想在手机上预览清楚就选放大 10 倍。")
                    }
                }
                Section {
                    Button { Task { await export() } } label: {
                        Label(running ? "正在导出…" : "导出 \(replacedCount) 个替换图标", systemImage: "shippingbox")
                    }
                    .disabled(running || replacedCount == 0)
                    if running {
                        ProgressView(value: Double(done), total: Double(max(total, 1))) {
                            Text("\(done) / \(total)").font(.caption).monospacedDigit()
                        }
                    }
                    if let summary, !running {
                        Label("已导出 \(summary.iconCount) 个图标，共 \(summary.fileCount) 个文件", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if !summary.skipped.isEmpty {
                            DisclosureGroup("有 \(summary.skipped.count) 项被跳过") {
                                ForEach(Array(summary.skipped.enumerated()), id: \.offset) { _, item in
                                    Text("\(item.icon)：\(item.reason)").font(.caption)
                                }
                            }
                        }
                        Button { save(summary.url) } label: { Label(saved ? "已保存" : "保存 zip 到“文件”", systemImage: "folder") }
                        Button { shareFile = ShareFile(url: summary.url) } label: { Label("分享 zip", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("导出替换图标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $shareFile) { ShareSheet(file: $0.url) }
            .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var replacedCount: Int { capture.choices.values.filter(\.replace).count }

    private var options: CaptureExportOptions {
        var options = CaptureExportOptions()
        options.scales = scales
        options.formats = formats.override ?? [.png, .svg]
        return options
    }

    private func export() async {
        running = true
        saved = false
        summary = nil
        defer { running = false }
        do {
            if target == .plugin {
                summary = try await PluginExporter.export(capture, options: options) { finished, count in
                    done = finished
                    total = count
                }
                return
            }
            let plan = capture.resolvedPlan(options)
            total = plan.icons.count
            let json = try capture.planJSON(options)
            var batch = BatchOptions()
            batch.svgScale = svgScale
            var result = try await BatchExporter.export(plan, options: batch, extras: ["plan.json": json]) { finished, count in
                done = finished
                total = count
            }
            for issue in plan.issues {
                result.skipped.append(BatchSummary.Skipped(icon: issue.icon ?? "-", reason: issue.message))
            }
            summary = result
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(_ url: URL) {
        if !DocumentPicker.save(url, saved: { saved = true }) { shareFile = ShareFile(url: url) }
    }
}
