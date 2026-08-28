import Foundation

enum FileNameSanitizer {
    private static let invalidCharacters = CharacterSet(charactersIn: "/:\\")

    static func fileName(from rawTitle: String, fallback: String = "Untitled") -> String {
        var value = clean(rawTitle, fallback: fallback, maxLength: 120)
        let lowercased = value.lowercased()
        if lowercased.hasSuffix(".md") {
            value = String(value.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? fallback : value
    }

    static func directoryName(from rawName: String, fallback: String = "Inbox") -> String {
        let value = clean(rawName, fallback: fallback, maxLength: 80)
        return [".", ".."].contains(value) ? fallback : value
    }

    private static func clean(_ rawValue: String, fallback: String, maxLength: Int) -> String {
        var value = rawValue
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")

        value = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        if value.isEmpty { value = fallback }
        if value.count > maxLength { value = String(value.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return value.isEmpty ? fallback : value
    }
}
