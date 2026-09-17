import Foundation
import NaturalLanguage

/// Script-level description of a note's text.
///
/// `NLLanguageRecognizer` is used as a *hint* only: on a machine without the language
/// identification assets it happily reports Hungarian for plain Chinese. The deterministic
/// script ratio is therefore the primary signal, and the recognizer only breaks ties.
struct LocalLanguageProfile: Equatable {
    enum Script: String, Equatable {
        case chinese
        case english
        case mixed
        case other
    }

    let chineseCount: Int
    let latinCount: Int
    let script: Script
    /// Recognizer hint, only kept when it agrees with a supported embedding language.
    let recognizerHint: String?

    var chineseRatio: Double {
        let total = chineseCount + latinCount
        guard total > 0 else { return 0 }
        return Double(chineseCount) / Double(total)
    }

    var isChineseDominant: Bool { script == .chinese }
    var isEnglishDominant: Bool { script == .english }

    /// Dominant embedding language, or nil when the text has no usable letters.
    var embeddingLanguage: String? {
        switch script {
        case .chinese: return LocalEmbeddingService.chineseLanguage
        case .english: return LocalEmbeddingService.englishLanguage
        case .mixed, .other:
            if chineseCount == 0 && latinCount == 0 { return nil }
            return chineseCount >= latinCount
                ? LocalEmbeddingService.chineseLanguage
                : LocalEmbeddingService.englishLanguage
        }
    }

    static func analyze(_ text: String) -> LocalLanguageProfile {
        var chinese = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                chinese += 1
            } else if isLatinLetter(scalar) {
                latin += 1
            }
        }

        let total = chinese + latin
        let script: Script
        if total == 0 {
            script = .other
        } else {
            let ratio = Double(chinese) / Double(total)
            if ratio >= 0.6 {
                script = .chinese
            } else if ratio <= 0.25 {
                script = .english
            } else {
                script = .mixed
            }
        }

        return LocalLanguageProfile(chineseCount: chinese,
                                    latinCount: latin,
                                    script: script,
                                    recognizerHint: hint(for: text, total: total))
    }

    private static func hint(for text: String, total: Int) -> String? {
        // Short strings and script-ambiguous mixtures are exactly where the recognizer is
        // least reliable, and the assets may not even be installed.
        guard total >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let supported = Set(LocalEmbeddingService.supportedLanguages())
        guard supported.contains(dominant.rawValue) else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard (hypotheses[dominant] ?? 0) >= 0.8 else { return nil }
        return dominant.rawValue
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }
}
