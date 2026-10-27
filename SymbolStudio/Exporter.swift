import Foundation
import SwiftUI
import UIKit

enum ExportFile {
    /// Writes into a fresh temporary folder so the shared file keeps a clean name.
    static func write(_ data: Data, name: String, fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymbolStudio-exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "_")
        let file = directory.appendingPathComponent(base + "." + fileExtension)
        try data.write(to: file, options: .atomic)
        return file
    }
}

struct ShareFile: Identifiable { let id = UUID(); let url: URL }

struct ShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
