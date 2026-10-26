import SwiftUI
import UIKit

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var query = ""
    @State private var scope = "all"
    @State private var showCategories = false
    @State private var showAbout = false
    @State private var useList = false
    @State private var matches: [SymbolItem] = []
    @State private var filtering = false

    private var filterKey: String {
        query + "|" + scope + "|" + store.favorites.sorted().joined(separator: ",")
            + "|" + store.recent.joined(separator: ",") + "|" + String(store.catalog?.symbols.count ?? 0)
    }
    private var scopeTitle: String {
        switch scope {
        case "all": return "全部图标"
        case "favorites": return "我的收藏"
        case "recent": return "最近使用"
        default: return store.catalog?.categories.first { $0.id == scope }?.title ?? "全部图标"
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Button { showCategories = true } label: {
                        HStack(spacing: 6) {
                            Text(scopeTitle).fontWeight(.semibold)
                            Image(systemName: "chevron.down").font(.caption.bold())
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if filtering { ProgressView().controlSize(.small) }
                    Text("\(matches.count) 个").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                resultContent
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("符号工坊")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索名称、中文或英文关键词")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { useList.toggle() } label: {
                            Label(useList ? "切换为网格" : "切换为列表",
                                  systemImage: useList ? "square.grid.2x2" : "list.bullet")
                        }
                        Button { showAbout = true } label: { Label("关于图标库", systemImage: "info.circle") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showCategories) { categorySheet }
            .sheet(isPresented: $showAbout) { AboutView() }
            .task(id: filterKey) { await filter() }
        }
    }

    @ViewBuilder private var resultContent: some View {
        if store.catalog == nil {
            if let error = store.startupError {
                StudioEmptyView(icon: "exclamationmark.triangle", title: "图标库加载失败", detail: error)
            } else { Spacer(); ProgressView("正在准备图标库…"); Spacer() }
        } else if matches.isEmpty {
            StudioEmptyView(icon: "magnifyingglass", title: "没有找到图标",
                            detail: scope == "favorites" ? "长按图标或在详情页点星标，即可收藏。" : "试试“聊天”“返回”“爱心”或英文名称。")
        } else if useList {
            List(matches) { item in
                NavigationLink { EditorView(item: item) } label: {
                    HStack(spacing: 14) {
                        SymbolGlyph(name: item.name, size: 24).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.semibold))
                            Text(item.keywords).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if store.favorites.contains(item.name) { Image(systemName: "star.fill").foregroundStyle(.orange) }
                    }.padding(.vertical, 3)
                }
                .contextMenu { contextActions(item) }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(matches) { item in
                        NavigationLink { EditorView(item: item) } label: { symbolCell(item) }
                            .buttonStyle(.plain)
                            .contextMenu { contextActions(item) }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func symbolCell(_ item: SymbolItem) -> some View {
        VStack(spacing: 10) {
            SymbolGlyph(name: item.name, size: 26).frame(width: 50, height: 50)
            Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                .multilineTextAlignment(.center).frame(height: 29, alignment: .top)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 5).padding(.vertical, 17)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            if store.favorites.contains(item.name) {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange).padding(9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityHint("打开配色和导出")
    }

    @ViewBuilder private func contextActions(_ item: SymbolItem) -> some View {
        Button { store.toggleFavorite(item.name) } label: {
            Label(store.favorites.contains(item.name) ? "取消收藏" : "收藏",
                  systemImage: store.favorites.contains(item.name) ? "star.slash" : "star")
        }
        Button { UIPasteboard.general.string = item.name } label: {
            Label("复制名称", systemImage: "doc.on.doc")
        }
    }

    private var categorySheet: some View {
        NavigationStack {
            List {
                Section {
                    scopeRow("all", "全部图标", "square.grid.2x2", store.catalog?.symbols.count ?? 0)
                    scopeRow("favorites", "我的收藏", "star", store.favorites.count)
                    scopeRow("recent", "最近使用", "clock", store.recent.count)
                }
                Section("分类") {
                    ForEach(store.catalog?.categories ?? []) { category in
                        scopeRow(category.id, category.title, category.icon, category.count)
                    }
                }
            }
            .navigationTitle("选择分类").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showCategories = false } } }
        }
    }

    private func scopeRow(_ id: String, _ title: String, _ icon: String, _ count: Int) -> some View {
        Button {
            scope = id; showCategories = false
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
                if scope == id { Image(systemName: "checkmark").foregroundStyle(.blue) }
            }
        }.foregroundStyle(.primary)
    }

    private func filter() async {
        filtering = true
        do {
            if !query.isEmpty { try await Task.sleep(nanoseconds: 130_000_000) }
            let symbols = store.catalog?.symbols ?? []
            let favorites = store.favorites, recent = store.recent, selected = scope
            let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let result = await Task.detached(priority: .userInitiated) {
                var filtered = symbols.filter { item in
                    let inScope: Bool
                    switch selected {
                    case "all": inScope = true
                    case "favorites": inScope = favorites.contains(item.name)
                    case "recent": inScope = recent.contains(item.name)
                    default: inScope = item.categories.contains(selected)
                    }
                    return inScope && tokens.allSatisfy { item.searchableText.lowercased().contains($0) }
                }
                if selected == "recent" {
                    let rank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
                    filtered.sort { (rank[$0.name] ?? Int.max) < (rank[$1.name] ?? Int.max) }
                }
                return filtered
            }.value
            try Task.checkCancellation(); matches = result; filtering = false
        } catch { }
    }
}

struct StudioEmptyView: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }.padding(32).frame(maxWidth: .infinity)
    }
}

@MainActor
struct DesignsView: View {
    @EnvironmentObject private var store: StudioStore
    var body: some View {
        NavigationStack {
            Group {
                if store.designs.isEmpty {
                    StudioEmptyView(icon: "paintpalette", title: "保存喜欢的配色",
                                    detail: "打开图标，调整颜色后点“保存配色”。这里会保留渲染模式、颜色、粗细和导出设置。")
                } else {
                    List {
                        ForEach(store.designs) { design in
                            if let item = store.item(named: design.symbolName) {
                                NavigationLink {
                                    EditorView(item: item, style: design.style, options: design.options)
                                } label: {
                                    HStack(spacing: 12) {
                                        StyledSymbol(name: item.name, style: design.style, pointSize: 24)
                                            .environment(\.colorScheme, design.style.appearance.colorScheme)
                                            .frame(width: 45, height: 45)
                                            .background(design.style.appearance == .dark ? Color(white: 0.11) : Color.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(design.title).font(.headline)
                                            Text(item.name).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 3)
                                }
                            }
                        }
                        .onDelete { indices in
                            let ids = indices.map { store.designs[$0].id }
                            ids.forEach { store.removeDesign($0) }
                        }
                    }
                }
            }
            .navigationTitle("我的配色")
        }
    }
}

@MainActor
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: StudioStore
    var body: some View {
        NavigationStack {
            List {
                Section("符号工坊 0.2.0") {
                    Text("当前系统可用 \(store.catalog?.symbols.count ?? 0) 个符号")
                    Text("渲染模式、调色板、多色、渐变、九种粗细，导出 SVG / PNG，复制 SwiftUI、UIKit、Objective-C 代码。")
                }
                Section("图标从哪里来") {
                    Text("App 不内置图标图形。导出时由系统按所选样式绘制符号，再把绘制出的矢量路径转换成 SVG，所以结果与当前系统一致。")
                    Text("搜索用的中文关键词和分类来自内置索引；索引里没有、但系统里有的新符号也会列出，只是没有关键词。")
                }
                Section("许可") {
                    Link("Apple SF Symbols", destination: URL(string: "https://developer.apple.com/sf-symbols/")!)
                    Text("SF Symbols 的图形权利属于 Apple。导出的素材只适合用于 Apple 平台的设计与开发，并需遵守 Apple 的许可条款。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
