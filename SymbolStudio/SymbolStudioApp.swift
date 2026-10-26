import SwiftUI

@main
@MainActor
struct SymbolStudioApp: App {
    @StateObject private var store = StudioStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryView().tabItem { Label("图标", systemImage: "square.grid.2x2") }
                DesignsView().tabItem { Label("我的配色", systemImage: "paintpalette") }
                BatchView().tabItem { Label("批量导出", systemImage: "square.and.arrow.down.on.square") }
            }
            .tint(Color(red: 0.10, green: 0.40, blue: 0.95))
            .environmentObject(store)
            .task {
                if SelfTest.isRequested { await SelfTest.run() }
                await store.load()
            }
        }
    }
}
