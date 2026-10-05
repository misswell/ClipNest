import Foundation

struct NoteFootnote: Identifiable {
    let id: String
    let text: String
}

enum NoteFootnotes {
    static func definitions(in text: String) -> [NoteFootnote] {
        let body = MarkdownKnowledge.body(text)
        let lines = body.components(separatedBy: "\n")
        let masked = MarkdownKnowledge.proseMask(body).components(separatedBy: "\n")
        var result: [NoteFootnote] = []
        for i in lines.indices {
            guard let match = MarkdownKnowledge.matches("^ {0,3}\\[\\^([^\\]\\n]+)\\]:[ \\t]*(.*)$", in: masked[i]).first else { continue }
            let ns = lines[i] as NSString
            var content = ns.substring(with: match.range(at: 2))
            var next = i + 1
            while next < lines.count, lines[next].hasPrefix("    ") || lines[next].hasPrefix("\t") {
                content += "\n" + lines[next].trimmingCharacters(in: .whitespaces)
                next += 1
            }
            result.append(NoteFootnote(id: ns.substring(with: match.range(at: 1)), text: content))
        }
        return result
    }

    static func inline(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for match in MarkdownKnowledge.matches("(?<![\\\\])\\[\\^([^\\]\\n]+)\\](?!:)", in: MarkdownKnowledge.proseMask(text)).reversed() {
            let id = (text as NSString).substring(with: match.range(at: 1))
            if let url = MarkdownKnowledge.navigationURL("#^fn-" + id) {
                result.replaceCharacters(in: match.range, with: "[" + id + "](" + url.absoluteString + ")")
            }
        }
        if let definition = MarkdownKnowledge.matches("^\\[\\^([^\\]]+)\\]:", in: result as String).first {
            let id = result.substring(with: definition.range(at: 1))
            result.replaceCharacters(in: definition.range, with: id + ".")
        }
        return result as String
    }
}
