import SwiftUI

@main
@MainActor
struct SymbolStudioApp: App {
    @StateObject private var store = StudioStore()
    @State private var tab = 0
    @State private var openedFile: URL?
    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                LibraryView().tabItem { Label("图标", systemImage: "square.grid.2x2") }.tag(0)
                DesignsView().tabItem { Label("我的配色", systemImage: "paintpalette") }.tag(1)
                BatchView(openedFile: $openedFile).tabItem { Label("批量导出", systemImage: "square.and.arrow.down.on.square") }.tag(2)
            }
            .onOpenURL { url in
                openedFile = url
                tab = 2
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
