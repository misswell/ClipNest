import Foundation

/// Reads fields out of a JSON answer **while it is still being written**.
///
/// The model streams `{"title":"…","summary":"…","category":"…","tags":[…]}` one fragment at a
/// time. `LocalGeneratedNoteDecoder` cannot help here: it needs the whole object, so calling it
/// mid-stream would fail on every frame but the last. This reads individual values tolerantly,
/// with no requirement that the object is closed.
///
/// The rules are driven by what the model actually emits:
///
/// - A value stays "open" until its closing quote arrives, so the last field is usually
///   partial — that is the point, it is the text the user watches grow.
/// - Escapes (`\"`, `\\`, `\n`, `\uXXXX`) decode as soon as they are complete. A trailing lone
///   backslash, or a `\u` missing digits, ends the value rather than rendering literal junk.
/// - A field that has not appeared yet returns `nil`, so the preview shows nothing instead of
///   an empty box.
///
/// This is **display-only**. It never feeds the saved note: `LocalGeneratedNoteDecoder` stays
/// the single authority on what the model said (§22), so a leniency here cannot corrupt a note.
enum LocalPartialJSON {
    /// The value of `key` as far as it has arrived, or `nil` if the key has not been seen.
    static func string(_ key: String, in raw: String) -> String? {
        guard let start = valueStart(for: key, in: raw) else { return nil }
        let value = readString(in: raw, from: start).value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The complete string elements of the array at `key`, in order.
    ///
    /// An element still being written is left out — a half-typed tag is worse than no tag,
    /// because it flickers as it grows.
    static func strings(_ key: String, in raw: String, limit: Int = 5) -> [String] {
        guard let bracket = arrayStart(for: key, in: raw) else { return [] }
        var out: [String] = []
        var index = raw.index(after: bracket)

        while index < raw.endIndex, out.count < limit {
            switch raw[index] {
            case "]":
                return out
            case "\"":
                let read = readString(in: raw, from: index)
                guard read.closed else { return out }
                let value = read.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { out.append(value) }
                index = read.end
            default:
                index = raw.index(after: index)
            }
        }
        return out
    }

    // MARK: - Locating keys

    /// Index of the opening quote of `key`'s string value, or `nil` when nothing has started.
    ///
    /// Returns `nil` if the quote is the last character received: the stream can end exactly
    /// there, and reporting "a value is starting" for a value with no characters would make the
    /// caller hand an out-of-range index to the reader.
    private static func valueStart(for key: String, in raw: String) -> String.Index? {
        guard let colon = colon(after: key, in: raw) else { return nil }
        var index = raw.index(after: colon)
        skipWhitespace(in: raw, index: &index)
        guard index < raw.endIndex, raw[index] == "\"" else { return nil }
        guard raw.index(after: index) < raw.endIndex else { return nil }
        return index
    }

    /// Index of the `[` opening `key`'s array.
    private static func arrayStart(for key: String, in raw: String) -> String.Index? {
        guard let colon = colon(after: key, in: raw) else { return nil }
        var index = raw.index(after: colon)
        skipWhitespace(in: raw, index: &index)
        guard index < raw.endIndex, raw[index] == "[" else { return nil }
        return index
    }

    /// The `:` that follows the `"key"` token, or `nil` if the key has not arrived yet.
    private static func colon(after key: String, in raw: String) -> String.Index? {
        // The quotes around the needle are what stop `"subtitle"` from matching `"title"`.
        let needle = "\"\(key)\""
        var searchStart = raw.startIndex
        while let found = raw.range(of: needle, range: searchStart..<raw.endIndex) {
            let escaped = found.lowerBound > raw.startIndex
                && raw[raw.index(before: found.lowerBound)] == "\\"
            if !escaped {
                var index = found.upperBound
                skipWhitespace(in: raw, index: &index)
                guard index < raw.endIndex else { return nil }   // key seen, colon pending
                return raw[index] == ":" ? index : nil
            }
            searchStart = found.upperBound
        }
        return nil
    }

    private static func skipWhitespace(in raw: String, index: inout String.Index) {
        while index < raw.endIndex, raw[index].isWhitespace {
            index = raw.index(after: index)
        }
    }

    // MARK: - String bodies

    /// Reads a quoted string whose opening quote is at `start`.
    ///
    /// `closed` is false when the input ran out first, which is the normal case for the field
    /// the model is currently writing.
    private static func readString(in raw: String,
                                   from start: String.Index) -> (value: String, end: String.Index, closed: Bool) {
        var out = ""
        guard start < raw.endIndex else { return (out, raw.endIndex, false) }
        var index = raw.index(after: start)
        guard index < raw.endIndex else { return (out, raw.endIndex, false) }

        while index < raw.endIndex {
            let character = raw[index]

            if character == "\\" {
                let markerIndex = raw.index(after: index)
                guard markerIndex < raw.endIndex else { return (out, raw.endIndex, false) }
                let marker = raw[markerIndex]

                if marker == "u" {
                    guard let (scalar, next) = readUnicodeEscape(in: raw, afterUMarker: markerIndex) else {
                        // Incomplete `\u` — the digits may still be arriving.
                        return (out, raw.endIndex, false)
                    }
                    out.append(scalar)
                    index = next
                    continue
                }

                out.append(Self.escape(marker))
                index = raw.index(after: markerIndex)
                continue
            }

            if character == "\"" {
                return (out, raw.index(after: index), true)
            }
            out.append(character)
            index = raw.index(after: index)
        }
        return (out, raw.endIndex, false)
    }

    /// Decodes `\uXXXX`, joining a surrogate pair when the low half is present.
    private static func readUnicodeEscape(in raw: String,
                                          afterUMarker index: String.Index) -> (Character, String.Index)? {
        guard let firstStart = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
              let firstEnd = raw.index(firstStart, offsetBy: 4, limitedBy: raw.endIndex),
              let unit = UInt32(raw[firstStart..<firstEnd], radix: 16) else { return nil }

        // Surrogates are checked as raw code units: `Unicode.Scalar` rejects 0xD800–0xDFFF, so
        // building one first would throw away every valid emoji before the pair could be joined.
        if (0xD800...0xDBFF).contains(unit) {
            guard firstEnd < raw.endIndex, raw[firstEnd] == "\\" else {
                // The partner has not arrived yet. Emitting half an emoji is worse than waiting.
                return nil
            }
            let lowMarker = raw.index(after: firstEnd)
            guard lowMarker < raw.endIndex, raw[lowMarker] == "u",
                  let lowStart = raw.index(lowMarker, offsetBy: 1, limitedBy: raw.endIndex),
                  let lowEnd = raw.index(lowStart, offsetBy: 4, limitedBy: raw.endIndex),
                  let low = UInt32(raw[lowStart..<lowEnd], radix: 16),
                  (0xDC00...0xDFFF).contains(low) else { return nil }

            let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { return nil }
            return (Character(scalar), lowEnd)
        }

        guard let scalar = Unicode.Scalar(unit) else { return nil }
        return (Character(scalar), firstEnd)
    }

    private static func escape(_ marker: Character) -> Character {
        switch marker {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        default:
            // Unknown escape: keep the character rather than dropping content.
            return marker
        }
    }
}
