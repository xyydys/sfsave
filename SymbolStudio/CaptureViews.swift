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

    var body: some View {
        NavigationStack {
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
                            Button { sheet = .bulk } label: { Label("一键套用风格…", systemImage: "wand.and.stars") }
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
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .bulk: BulkApplySheet { count in showToast("已套用到 \(count) 个图标") }
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
            Text("选抓图工具导出的 zip（里面有 manifest.json 和 icons 文件夹）。导入后每个素材都会列出来，可以一个一个选替换的符号和配色，也可以先一键套用一种风格再细调。")
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
            Section { CaptureSummary(sheet: $sheet) }
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
                var text = "新增 \(result.added) 个素材"
                if result.updated > 0 { text += "，已有的 \(result.updated) 个只补了尺寸和颜色" }
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
    case bulk, export, backups
    var id: String { rawValue }
}

private struct CaptureSummary: View {
    @EnvironmentObject private var capture: CaptureStore
    @Binding var sheet: CaptureSheet?

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
        Button { sheet = .bulk } label: { Label("一键套用风格…", systemImage: "wand.and.stars") }
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
            ReplacementThumb(choice: capture.choices[icon.name], side: 40)
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill((dark ?? icon.prefersDarkTile) ? Color(white: 0.2) : Color(white: 0.94))
            if let image = capture.image(for: icon) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.12)
            }
        }
        .frame(width: side, height: side)
    }
}

struct ReplacementThumb: View {
    let choice: IconChoice?
    var side: CGFloat
    var dark = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(dark ? Color(white: 0.12) : Color(white: 0.985))
                .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).stroke(.gray.opacity(0.2), lineWidth: 1))
            if let choice, choice.replace {
                LookSymbol(symbol: choice.symbol, look: choice.look, side: side)
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
    @State private var name: String
    @State private var showPicker = false
    @State private var rendered: UIImage?
    @State private var darkTiles: Bool?

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
        let saved = capture.choices[icon.name]
        return List {
            if let update = icon.update { updateSection(icon, update) }
            Section {
                compare(icon, choice: saved)
                actualSize(icon, choice: saved)
            } footer: {
                Text("右边是按导出设置画出来的效果：和原图同样的画布大小，放在原图内容所在的位置。")
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
                symbolStrip(icon, choice: choice)
            } header: {
                Text("符号")
            } footer: {
                Text("前几个是按这个素材的用途挑的。点放大镜按分类找，也可以直接搜索（中英文都行）。")
            }
            Section {
                presetGrid(icon, choice: choice)
            } header: {
                Text("风格")
            }
            Section {
                LookEditor(look: lookBinding(icon))
            } header: {
                Text("自定义")
            } footer: {
                Text("改了这里就不再算作某个预设。渐变：点“加渐变”后选结束色，角度对所有层生效。")
            }
            Section {
                info(icon)
            } header: {
                Text("素材信息")
            }
        }
        .sheet(isPresented: $showPicker) {
            SymbolPickerSheet(look: choice.look) { symbol in update(icon) { $0.symbol = symbol } }
        }
        .task(id: RenderKey(name: icon.name, choice: saved)) { render(icon, choice: saved) }
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
                        if let rendered, choice?.replace == true {
                            Image(uiImage: rendered).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(14)
                        } else if let image = capture.image(for: icon) {
                            Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(14)
                                .opacity(0.35)
                        }
                    }
                    .frame(width: 120, height: 120)
                    Text(choice?.replace == true ? "替换后" : "未替换").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("底色", selection: Binding(get: { dark }, set: { darkTiles = $0 })) {
                Text("浅底").tag(false)
                Text("深底").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
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

    private func symbolStrip(_ icon: CaptureIcon, choice: IconChoice) -> some View {
        var candidates = capture.symbols(for: icon)
        if !candidates.contains(choice.symbol), UIImage(systemName: choice.symbol) != nil { candidates.insert(choice.symbol, at: 0) }
        let selected = capture.choices[icon.name]?.replace == true ? choice.symbol : nil
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(candidates, id: \.self) { symbol in
                    Button { update(icon) { $0.symbol = symbol } } label: {
                        OptionTile(selected: symbol == selected, caption: symbol) {
                            LookSymbol(symbol: symbol, look: choice.look, side: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button { showPicker = true } label: {
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
        let selected = capture.choices[icon.name]?.replace == true ? choice.presetID : nil
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 10)], spacing: 12) {
            ForEach(LookPreset.all) { preset in
                Button {
                    update(icon) { $0.look = preset.look(for: icon); $0.presetID = preset.id }
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

    private func lookBinding(_ icon: CaptureIcon) -> Binding<IconLook> {
        Binding(get: { capture.choice(for: icon).look }, set: { look in
            update(icon) { $0.look = look; $0.presetID = nil }
        })
    }

    /// Changes the icon's choice and marks it as replaced by hand, which
    /// keeps bulk apply away from it.
    private func update(_ icon: CaptureIcon, _ change: (inout IconChoice) -> Void) {
        var choice = capture.choice(for: icon)
        change(&choice)
        choice.replace = true
        choice.manual = true
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
    }

    /// The replacement exactly as the export draws it.
    private func render(_ icon: CaptureIcon, choice: IconChoice?) {
        guard let choice, choice.replace else { rendered = nil; return }
        let style = choice.look.style(pointSize: 64)
        guard let drawing = SymbolPipeline.renderDrawing(name: choice.symbol, style: style) else { rendered = nil; return }
        let box = capture.box(for: icon, look: choice.look, options: CaptureExportOptions())
        let layout = SVGWriter.layout(for: drawing.drawing, frame: drawing.frame, width: icon.canvas.width,
                                      height: icon.canvas.height, padding: 0.1, fit: .contain, box: box)
        let scale = max(3, 120 / max(icon.canvas.width, icon.canvas.height))
        rendered = SymbolPipeline.rasterize(pdf: drawing.pdf, layout: layout, pixelScale: scale, background: nil)
            .flatMap { UIImage(data: $0, scale: scale) }
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
        LabeledContent("大小 \(Int((look.size * 100).rounded()))%") {
            Slider(value: $look.size, in: 0.5...1.5, step: 0.05).frame(maxWidth: 190)
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

struct BulkApplySheet: View {
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    let done: (Int) -> Void
    @State private var presetID = LookPreset.all[0].id
    @State private var overwriteBulk = false
    @State private var overwriteManual = false

    private let samples = ["heart.fill", "camera.fill", "magnifyingglass", "person.2.fill"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LookPreset.all) { preset in
                        Button { presetID = preset.id } label: {
                            HStack(spacing: 8) {
                                ForEach(samples, id: \.self) { symbol in
                                    LookSymbol(symbol: symbol, look: preset.look(for: nil), side: 40).frame(width: 40, height: 40)
                                }
                                Text(preset.title).foregroundStyle(.primary)
                                Spacer()
                                if preset.id == presetID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: {
                    Text("选一种风格")
                }
                Section {
                    Toggle("也改之前一键套用的", isOn: $overwriteBulk)
                    Toggle("也改我逐个调过的", isOn: $overwriteManual)
                        .tint(.red)
                    LabeledContent("会改动", value: "\(capture.bulkCount(overwriteBulk: overwriteBulk, overwriteManual: overwriteManual)) 个图标")
                } footer: {
                    Text("默认只给待定的图标套风格（用推荐的第一个符号）；你逐个调过的、标了“不替换”的和装饰类素材都不动。打开开关会改到已有的设置，改之前会自动备份，可在菜单“恢复替换设置”里找回。已选过的符号保留不变。")
                }
            }
            .navigationTitle("一键套用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("套用") {
                        guard let preset = LookPreset.named(presetID) else { return }
                        done(capture.apply(preset, overwriteBulk: overwriteBulk, overwriteManual: overwriteManual))
                        dismiss()
                    }
                }
            }
        }
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
    @EnvironmentObject private var capture: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var scales = [3]
    @State private var formats = BatchFormats.both
    @State private var align = true
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
                    Toggle("对齐原图位置", isOn: $align)
                } footer: {
                    Text("文件按微信素材名命名：name@3x.png，SVG 在 svg/ 文件夹。画布和原图一样大；对齐原图位置时，图形放在原图内容所在的矩形里。zip 里还有 plan.json，可以在“批量导出”页重新导入。")
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
        options.alignToOriginal = align
        return options
    }

    private func export() async {
        running = true
        saved = false
        summary = nil
        defer { running = false }
        do {
            let plan = capture.resolvedPlan(options)
            total = plan.icons.count
            let json = try capture.planJSON(options)
            var result = try await BatchExporter.export(plan, options: BatchOptions(), extras: ["plan.json": json]) { finished, count in
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
