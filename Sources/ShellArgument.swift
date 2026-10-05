import Foundation

enum ShellArgument {
    /// One literal POSIX shell argument, including quotes, newlines and substitution syntax.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
