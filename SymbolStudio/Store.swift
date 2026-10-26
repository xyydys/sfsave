import Foundation
import SwiftUI
import UIKit

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
        if let data = defaults.data(forKey: "designs.v2") {
            designs = (try? JSONDecoder().decode([SavedDesign].self, from: data)) ?? []
        }
    }

    func load() async {
        guard catalog == nil else { return }
        do {
            catalog = try await Task.detached(priority: .userInitiated) { try Self.loadCatalog() }.value
        } catch { startupError = error.localizedDescription }
    }

    /// The bundled catalog supplies keywords and categories; the device decides
    /// which names actually exist. Symbols the bundled list does not know about
    /// are added from the system's own name list when it can be read.
    nonisolated private static func loadCatalog() throws -> SymbolCatalog {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Resources")
        else { throw StudioError.resource("缺少图标目录，请检查工程 Resources 文件夹是否随 App 打包。") }
        var catalog = try JSONDecoder().decode(SymbolCatalog.self, from: Data(contentsOf: url))
        catalog.symbols = catalog.symbols.filter { UIImage(systemName: $0.name) != nil }
        let known = Set(catalog.symbols.map(\.name))
        let extra = systemSymbolNames().filter { !known.contains($0) && UIImage(systemName: $0) != nil }
        catalog.symbols += extra.sorted().map { SymbolItem(name: $0, categories: [], keywords: "") }
        for index in catalog.categories.indices {
            let id = catalog.categories[index].id
            catalog.categories[index].count = catalog.symbols.filter { $0.categories.contains(id) }.count
        }
        catalog.categories.removeAll { $0.count == 0 }
        return catalog
    }

    nonisolated private static func systemSymbolNames() -> [String] {
        let path = "/System/Library/CoreServices/CoreGlyphs.bundle/name_availability.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let symbols = plist["symbols"] as? [String: Any] else { return [] }
        return Array(symbols.keys)
    }

    func toggleFavorite(_ name: String) {
        if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
        defaults.set(Array(favorites), forKey: "favorites.v1")
    }
    func recordRecent(_ name: String) {
        recent.removeAll { $0 == name }; recent.insert(name, at: 0)
        recent = Array(recent.prefix(80)); defaults.set(recent, forKey: "recent.v1")
    }
    func saveDesign(name: String, title: String, style: SymbolStyle, options: ExportOptions) throws {
        var updated = designs
        updated.insert(SavedDesign(title: title.isEmpty ? name : title, symbolName: name, style: style, options: options), at: 0)
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: "designs.v2"); designs = updated
    }
    func removeDesign(_ id: UUID) {
        designs.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(designs) { defaults.set(data, forKey: "designs.v2") }
    }
    func item(named name: String) -> SymbolItem? { catalog?.symbols.first { $0.name == name } }
}
