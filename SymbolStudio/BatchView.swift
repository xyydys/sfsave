import SwiftUI
import UIKit

@MainActor
struct BatchView: View {
    /// A plan handed to the app with "Open in" from Files or another app.
    @Binding var openedFile: URL?
    @State private var plan: ResolvedPlan?
    @State private var source: String?
    @State private var loadError: String?
    @State private var options = BatchOptions()
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var summary: BatchSummary?
    @State private var shareFile: ShareFile?
    @State private var errorMessage: String?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                planSection
                if let loadError { Section { Label(loadError, systemImage: "xmark.octagon.fill").foregroundStyle(.red) } header: { Text("读取失败") } }
                if let plan {
                    if !plan.issues.isEmpty { issuesSection(plan) }
                    exportSection(plan)
                    iconsSection(plan)
                }
            }
            .navigationTitle("批量导出")
            .task(id: openedFile) {
                guard let url = openedFile else { return }
                openedFile = nil
                loadFile(url)
            }
            .sheet(item: $shareFile) { ShareSheet(file: $0.url) }
            .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
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
            .animation(.easeOut(duration: 0.2), value: toast)
        }
    }

    // MARK: Sections

    private var planSection: some View {
        Section {
            if let plan {
                LabeledContent("方案", value: plan.name)
                if let source { LabeledContent("来源", value: source) }
                LabeledContent("图标", value: "\(plan.icons.count) 个可导出")
            }
            Button { pickPlan() } label: { Label(plan == nil ? "导入方案 JSON…" : "换一个方案…", systemImage: "doc.badge.plus") }
            Button { pastePlan() } label: { Label("从剪贴板导入", systemImage: "doc.on.clipboard") }
            Button { loadSample() } label: { Label("载入示例方案", systemImage: "wand.and.stars") }
            Button { copySample() } label: { Label("复制示例 JSON", systemImage: "doc.on.doc") }
            if plan != nil {
                Button(role: .destructive) { clear() } label: { Label("清除", systemImage: "trash") }
            }
        } header: {
            Text("图标方案")
        } footer: {
            Text("方案是一份 JSON：每个图标写明输出文件名、用哪个 SF Symbol、渲染模式、浅色和深色配色、尺寸和 @2x / @3x。先“载入示例方案”看看格式，再复制示例改成自己的。\n也可以在“文件”或聊天 App 里点 JSON 文件，选“用其他应用打开”→ 符号工坊；或者复制 JSON 全文后点“从剪贴板导入”。")
        }
    }

    private func issuesSection(_ plan: ResolvedPlan) -> some View {
        Section {
            ForEach(Array(plan.issues.prefix(200))) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(issue.message).font(.subheadline)
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                    if let icon = issue.icon { Text(icon).font(.caption).foregroundStyle(.secondary).padding(.leading, 28) }
                }
            }
        } header: {
            Text("检查结果：\(plan.errorCount) 个错误，\(plan.warningCount) 个提醒")
        } footer: {
            Text(plan.errorCount > 0 ? "有错误的图标不会导出，其余照常导出。改好 JSON 后重新导入即可。" : "提醒不影响导出。")
        }
    }

    private func exportSection(_ plan: ResolvedPlan) -> some View {
        Section {
            Picker("格式", selection: $options.formats) {
                ForEach(BatchFormats.allCases) { Text($0.title).tag($0) }
            }
            Toggle("包含深色版本", isOn: $options.includeDark)
            Picker("SVG 标注尺寸", selection: $options.svgScale) {
                Text("和画布一样").tag(CGFloat(1))
                Text("放大 10 倍").tag(CGFloat(10))
            }
            LabeledContent("将生成", value: "\(plan.fileCount(options)) 个文件")
            Button { Task { await export(plan) } } label: {
                Label(running ? "正在导出…" : "导出为 zip", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(running || plan.icons.isEmpty)
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
                Button { saveZip(summary.url) } label: { Label("保存 zip 到“文件”", systemImage: "folder") }
                Button { shareFile = ShareFile(url: summary.url) } label: { Label("分享 zip", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("导出")
        } footer: {
            Text("zip 里按方案命名：name.png、name@2x.png、name_dark@2x.png，SVG 放在 svg/ 文件夹，另有 manifest.json 记录每个文件的尺寸。文件名规则可在方案的 output 字段里改。")
        }
    }

    private func iconsSection(_ plan: ResolvedPlan) -> some View {
        Section {
            ForEach(plan.icons) { PlanIconRow(icon: $0) }
        } header: {
            Text("预览")
        } footer: {
            Text("预览按所选渲染模式和颜色画出符号，实际导出时还会按 canvas 和 fit 缩放。")
        }
    }

    // MARK: Actions

    private func pickPlan() {
        if !DocumentPicker.open(PlanFile.types, picked: { loadFile($0) }) {
            errorMessage = "打不开文件选择器。可以复制 JSON 全文后点“从剪贴板导入”。"
        }
    }

    private func loadFile(_ url: URL) {
        do { try load(PlanFile.read(url), source: url.lastPathComponent) }
        catch { fail(error) }
    }

    private func pastePlan() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "剪贴板里没有文字。先在别的 App 里全选并复制方案 JSON，再回来点这里。"
            return
        }
        do { try load(Data(text.utf8), source: "剪贴板") }
        catch { fail(error) }
    }

    private func saveZip(_ url: URL) {
        if !DocumentPicker.save(url, saved: { showToast("已保存压缩包") }) { shareFile = ShareFile(url: url) }
    }

    private func loadSample() {
        do {
            guard let url = Bundle.main.url(forResource: "sample-plan", withExtension: "json") else {
                throw StudioError.resource("缺少示例方案 sample-plan.json。")
            }
            try load(Data(contentsOf: url), source: "示例")
        } catch { fail(error) }
    }

    private func copySample() {
        guard let url = Bundle.main.url(forResource: "sample-plan", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "缺少示例方案 sample-plan.json。"
            return
        }
        UIPasteboard.general.string = text
        showToast("已复制示例 JSON")
    }

    private func load(_ data: Data, source: String) throws {
        let resolved = try IconPlan.decode(data).resolve()
        plan = resolved
        self.source = source
        loadError = nil
        summary = nil
    }

    private func fail(_ error: Error) {
        loadError = error.localizedDescription
        plan = nil
        summary = nil
    }

    private func clear() {
        plan = nil; source = nil; loadError = nil; summary = nil
    }

    private func export(_ plan: ResolvedPlan) async {
        running = true
        done = 0
        total = plan.icons.count
        summary = nil
        defer { running = false }
        do {
            summary = try await BatchExporter.export(plan, options: options) { finished, count in
                done = finished
                total = count
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if toast == text { toast = nil }
        }
    }
}

struct PlanIconRow: View {
    let icon: ResolvedIcon

    var body: some View {
        HStack(spacing: 10) {
            ForEach(icon.appearances, id: \.self) { appearance in
                StyledSymbol(name: icon.symbol, style: icon.style(for: appearance), pointSize: 26)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: 46, height: 46)
                    .background(appearance == .dark ? Color(white: 0.11) : Color.white,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.gray.opacity(0.25), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(icon.names.joined(separator: "、")).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let scales = icon.scales.map { $0 == 1 ? "@1x" : "@\($0)x" }.joined(separator: " ")
        let size = "\(SVGWriter.number(icon.canvas.width))×\(SVGWriter.number(icon.canvas.height))"
        return "\(icon.symbol) · \(icon.mode.rawValue) · \(size) · \(scales)"
    }
}
