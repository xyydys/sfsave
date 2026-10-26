import Foundation
import SwiftUI

actor GlyphStore {
    static let shared = GlyphStore()
    private var cache: [String: VectorGlyph] = [:]
    private var order: [String] = []

    func load(_ name: String) throws -> VectorGlyph {
        if let glyph = cache[name] { return glyph }
        guard !name.contains("/"), !name.contains("\\"),
              let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Resources/Glyphs")
        else { throw StudioError.resource("找不到图标资源：\(name)") }
        let data = try Data(contentsOf: url)
        let glyph = try JSONDecoder().decode(VectorGlyph.self, from: data)
        guard glyph.viewBox.count == 4, glyph.viewBox[2] > 0, glyph.viewBox[3] > 0, !glyph.parts.isEmpty
        else { throw StudioError.resource("图标资源格式异常：\(name)") }
        cache[name] = glyph; order.append(name)
        if order.count > 180 { cache.removeValue(forKey: order.removeFirst()) }
        return glyph
    }
}

@MainActor
final class StudioStore: ObservableObject {
    @Published private(set) var catalog: SymbolCatalog?
    @Published var startupError: String?
    @Published var favorites: Set<String> = []
    @Published var recent: [String] = []
    @Published var designs: [SavedDesign] = []
    private let defaults = UserDefaults.standard

    init() {
        favorites = Set(defaults.stringArray(forKey: "favorites.v1") ?? [])
        recent = defaults.stringArray(forKey: "recent.v1") ?? []
        if let data = defaults.data(forKey: "designs.v1") {
            designs = (try? JSONDecoder().decode([SavedDesign].self, from: data)) ?? []
        }
    }

    func load() async {
        guard catalog == nil else { return }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> SymbolCatalog in
                guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Resources")
                else { throw StudioError.resource("缺少图标目录，请检查工程 Resources 文件夹是否随 App 打包。") }
                return try JSONDecoder().decode(SymbolCatalog.self, from: Data(contentsOf: url))
            }.value
            catalog = loaded
        } catch { startupError = error.localizedDescription }
    }

    func toggleFavorite(_ name: String) {
        if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
        defaults.set(Array(favorites), forKey: "favorites.v1")
    }
    func recordRecent(_ name: String) {
        recent.removeAll { $0 == name }; recent.insert(name, at: 0)
        recent = Array(recent.prefix(80)); defaults.set(recent, forKey: "recent.v1")
    }
    func saveDesign(name: String, title: String, style: ExportStyle) throws {
        var updated = designs
        updated.insert(SavedDesign(title: title.isEmpty ? name : title, symbolName: name, style: style), at: 0)
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: "designs.v1"); designs = updated
    }
    func removeDesign(_ id: UUID) {
        designs.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(designs) { defaults.set(data, forKey: "designs.v1") }
    }
    func item(named name: String) -> SymbolItem? { catalog?.symbols.first { $0.name == name } }
}
