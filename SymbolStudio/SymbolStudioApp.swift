import SwiftUI

@main
@MainActor
struct SymbolStudioApp: App {
    @StateObject private var store = StudioStore()
    @StateObject private var capture = CaptureStore()
    @State private var tab = 0
    @State private var openedFile: URL?
    @State private var openedZip: URL?
    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                LibraryView().tabItem { Label("图标", systemImage: "square.grid.2x2") }.tag(0)
                DesignsView().tabItem { Label("我的配色", systemImage: "paintpalette") }.tag(1)
                CaptureView(openedZip: $openedZip).tabItem { Label("逐个替换", systemImage: "square.grid.3x3.square") }.tag(2)
                BatchView(openedFile: $openedFile).tabItem { Label("批量导出", systemImage: "square.and.arrow.down.on.square") }.tag(3)
            }
            .onOpenURL { url in
                // A capture zip goes to the per-icon screen, a plan JSON to the batch screen.
                if url.pathExtension.lowercased() == "zip" {
                    openedZip = url
                    tab = 2
                } else {
                    openedFile = url
                    tab = 3
                }
            }
            .tint(Color(red: 0.10, green: 0.40, blue: 0.95))
            .environmentObject(store)
            .environmentObject(capture)
            .task {
                if SelfTest.isRequested { await SelfTest.run() }
                await store.load()
            }
        }
    }
}
