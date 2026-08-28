import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Reads the pasteboard only while the app is active. iOS therefore presents the normal
/// system paste permission prompt; no private API or background polling is used.
@MainActor
protocol ClipboardProviding: AnyObject {
    func changeCount() -> Int
    func readCurrent() -> ClipboardSnapshot?
}

@MainActor
final class ClipboardService: ClipboardProviding {
    func changeCount() -> Int {
        #if os(iOS)
        return UIPasteboard.general.changeCount
        #elseif os(macOS)
        return NSPasteboard.general.changeCount
        #else
        return 0
        #endif
    }

    func readCurrent() -> ClipboardSnapshot? {
        #if os(iOS)
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        let text = pasteboard.string ?? pasteboard.url?.absoluteString
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
            ?? (pasteboard.propertyList(forType: .URL) as? String)
        #else
        let changeCount = 0
        let text: String? = nil
        #endif

        guard let text, let content = ContentAnalyzer().analyze(text) else { return nil }
        return ClipboardSnapshot(
            content: content,
            changeCount: changeCount,
            hash: ClipboardContent.hash(for: content.rawText)
        )
    }
}
