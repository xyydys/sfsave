import Foundation
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker from UIKit. SwiftUI's `fileImporter`
/// and `fileExporter` share one presentation slot per view, so with both on a
/// screen one of them silently does nothing; presenting the picker directly
/// avoids that and works the same however the app was installed.
@MainActor
enum DocumentPicker {
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let finish: ([URL]) -> Void
        init(finish: @escaping ([URL]) -> Void) { self.finish = finish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
    }

    /// Kept alive while a picker is on screen; the picker only holds it weakly.
    private static var active: Delegate?

    /// Lets the user pick one file; the app receives its own copy of it.
    @discardableResult
    static func open(_ types: [UTType], picked: @escaping (URL) -> Void) -> Bool {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        return present(picker) { urls in if let url = urls.first { picked(url) } }
    }

    /// Lets the user choose where in Files to save a copy of `file`.
    @discardableResult
    static func save(_ file: URL, saved: @escaping () -> Void) -> Bool {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        return present(picker) { urls in if !urls.isEmpty { saved() } }
    }

    private static func present(_ picker: UIDocumentPickerViewController, finish: @escaping ([URL]) -> Void) -> Bool {
        guard let host = topController() else { return false }
        let delegate = Delegate { urls in
            active = nil
            finish(urls)
        }
        active = delegate
        picker.delegate = delegate
        host.present(picker, animated: true)
        return true
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

enum PlanFile {
    static let types: [UTType] = [.json, .plainText, .text, .data]

    /// Reads a plan from a picked or opened file, including files that are
    /// opened in place from another app or still downloading from iCloud.
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
