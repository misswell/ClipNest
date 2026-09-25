import Foundation
@testable import ClipNest

// Shared `NoteFormatConfiguration` fixtures (方案 §34): the two legacy `LocalBodyStyle`
// values expressed through the unified configuration, so prompt/body tests can keep pinning
// the behaviours those styles stood for.
extension NoteFormatConfiguration {
    /// The old `.sourceVerbatim`: the model writes title/summary/tags/category and the body
    /// is the user's own text. Identical to the shipping default.
    static var legacySourceVerbatim: NoteFormatConfiguration {
        NoteFormatConfiguration.standard
    }

    /// The old `.modelRewrite`: the model also writes the body, with the fact-preservation
    /// guard as the safety net.
    static var legacyModelRewrite: NoteFormatConfiguration {
        NoteFormatConfiguration.archive
    }
}
