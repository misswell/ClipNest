import Foundation
import Yams

struct BaseContext: Sendable {
    let root: URL
    let url: URL
    let lookup: NoteLinkResolver
    let formulas: [String: CanvasValue]
    var currentNote: NoteKnowledge? = nil
}

enum BaseExpression {
    static func compare(_ a: CanvasValue, _ b: CanvasValue) -> ComparisonResult {
        if a == b { return .orderedSame }
        if a == .null { return .orderedAscending }
        if b == .null { return .orderedDescending }
        if let x = a.number, let y = b.number { return x < y ? .orderedAscending : .orderedDescending }
        return display(a).localizedStandardCompare(display(b))
    }
    static func truthy(_ value: CanvasValue) -> Bool {
        switch value {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .object(let value): return !value.isEmpty
        case .null: return false
        }
    }
    static func display(_ value: CanvasValue) -> String {
        switch value {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        case .array(let values): return values.map(display).joined(separator: ", ")
        case .object: return (try? YAMLEncoder().encode(value))?.trimmingCharacters(in: .newlines) ?? ""
        }
    }

    /// Pure, bounded expression evaluation. No shell, JavaScript, or arbitrary code runs.
    static func evaluate(_ expression: String, note: NoteKnowledge, context: BaseContext,
                         depth: Int = 0, visiting: Set<String> = []) throws -> CanvasValue {
        guard depth < 40, expression.count <= 4096 else { throw failure(expression) }
        var text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("("), text.hasSuffix(")"), encloses(text) { text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        func eval(_ value: String) throws -> CanvasValue { try evaluate(value, note: note, context: context, depth: depth + 1, visiting: visiting) }
        for operation in ["||", "&&"] {
            if let split = split(text, operations: [operation]) {
                let a = try eval(split.0)
                if operation == "||", truthy(a) { return .bool(true) }
                if operation == "&&", !truthy(a) { return .bool(false) }
                return .bool(truthy(try eval(split.2)))
            }
        }
        if let split = split(text, operations: ["==", "!=", ">=", "<=", ">", "<"]) {
            let a = try eval(split.0), b = try eval(split.2)
            if split.1 == "==" { return .bool(a == b) }
            if split.1 == "!=" { return .bool(a != b) }
            if a == .null || b == .null { return .bool(false) }
            let result: ComparisonResult
            if let a = a.number, let b = b.number { result = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending }
            else { result = display(a).compare(display(b)) }
            switch split.1 {
            case ">": return .bool(result == .orderedDescending)
            case "<": return .bool(result == .orderedAscending)
            case ">=": return .bool(result != .orderedAscending)
            default: return .bool(result != .orderedDescending)
            }
        }
        if text.hasPrefix("!"), !text.hasPrefix("!=") { return .bool(!truthy(try eval(String(text.dropFirst())))) }
        if let numeric = Double(text), numeric.isFinite { return .number(numeric) }
        for operations in [["+", "-"], ["*", "/", "%"]] {
            if let split = split(text, operations: operations) {
                let a = try eval(split.0), b = try eval(split.2)
                if split.1 == "+", a.string != nil || b.string != nil { return .string(display(a) + display(b)) }
                guard let x = a.number, let y = b.number else { throw failure(text) }
                let value: Double
                switch split.1 {
                case "+": value = x + y
                case "-": value = x - y
                case "*": value = x * y
                case "/": guard y != 0 else { throw failure(text) }; value = x / y
                default: guard y != 0 else { throw failure(text) }; value = x.truncatingRemainder(dividingBy: y)
                }
                guard value.isFinite else { throw failure(text) }
                return .number(value)
            }
        }
        if text.hasPrefix("-") { guard let value = try eval(String(text.dropFirst())).number else { throw failure(text) }; return .number(-value) }
        if let match = MarkdownKnowledge.matches("^(.+)\\.toFixed\\(([0-9]+)\\)$", in: text).first {
            let ns = text as NSString
            guard let value = try eval(ns.substring(with: match.range(at: 1))).number,
                  let places = Int(ns.substring(with: match.range(at: 2))), places <= 12 else { throw failure(text) }
            return .string(String(format: "%.*f", places, value))
        }
        if let call = MarkdownKnowledge.matches("^([A-Za-z_][A-Za-z0-9_.]*)\\((.*)\\)$", in: text).first {
            let ns = text as NSString
            let function = ns.substring(with: call.range(at: 1))
            let arguments = arguments(ns.substring(with: call.range(at: 2)))
            if function == "if", arguments.count == 3 { return try eval(truthy(try eval(arguments[0])) ? arguments[1] : arguments[2]) }
            let values = try arguments.map(eval)
            switch function {
            case "file.hasTag":
                guard values.count == 1, let tag = values[0].string else { throw failure(text) }
                return .bool(note.tags.contains { $0 == tag || $0.hasPrefix(tag + "/") })
            case "file.inFolder":
                guard values.count == 1, let folder = values[0].string else { throw failure(text) }
                let path = MarkdownKnowledge.relativePath(note.url, to: context.root)
                return .bool(folder.isEmpty || path.hasPrefix(folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"))
            case "file.hasLink":
                guard values.count == 1, let target = values[0].string else { throw failure(text) }
                let resolved = context.lookup.resolve(target, from: note.url)
                return .bool(resolved != nil && note.links.contains { context.lookup.resolve($0.target, from: note.url) == resolved })
            case "list": return .array(values)
            case "number":
                guard values.count == 1, let value = Double(display(values[0])), value.isFinite else { throw failure(text) }
                return .number(value)
            case "string": guard values.count == 1 else { throw failure(text) }; return .string(display(values[0]))
            case "min", "max":
                let numbers = values.compactMap(\.number)
                guard !numbers.isEmpty, numbers.count == values.count else { throw failure(text) }
                return .number(function == "min" ? numbers.min()! : numbers.max()!)
            case "round", "floor", "ceil":
                guard values.count == 1, let number = values[0].number else { throw failure(text) }
                return .number(function == "round" ? number.rounded() : function == "floor" ? number.rounded(.down) : number.rounded(.up))
            default:
                let methods = [".contains", ".startsWith", ".endsWith"]
                if let method = methods.first(where: { function.hasSuffix($0) }), values.count == 1 {
                    let value = try eval(String(function.dropLast(method.count)))
                    if method == ".contains", case let .array(array) = value { return .bool(array.contains(values[0])) }
                    let string = display(value), argument = display(values[0])
                    return .bool(method == ".contains" ? string.contains(argument) : method == ".startsWith" ? string.hasPrefix(argument) : string.hasSuffix(argument))
                }
                throw failure(text)
            }
        }
        if text.hasPrefix("\""), text.hasSuffix("\"") { return .string(try JSONDecoder().decode(String.self, from: Data(text.utf8))) }
        if text.hasPrefix("'"), text.hasSuffix("'") { return .string(String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\'", with: "'")) }
        if let item = MarkdownKnowledge.matches("^(.+)\\[([^\\[\\]]+)\\]$", in: text).first {
            let ns = text as NSString
            let owner = ns.substring(with: item.range(at: 1))
            let key = try eval(ns.substring(with: item.range(at: 2)))
            if owner == "formula", let name = key.string { return try eval("formula." + name) }
            let value: CanvasValue
            if owner == "note" { value = .object(note.values) }
            else if owner == "this" { value = .object(context.currentNote?.values ?? [:]) }
            else { value = try eval(owner) }
            if let object = value.object, let key = key.string { return object[key] ?? .null }
            if let array = value.array, let index = key.number, index.rounded() == index, index >= 0, index < Double(array.count) { return array[Int(index)] }
            if value == .null { return .null }
            throw failure(text)
        }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text == "null" { return .null }
        if text.hasPrefix("formula.") {
            let name = String(text.dropFirst(8))
            guard !visiting.contains(name), let expression = context.formulas[name]?.string else { throw failure(text) }
            return try evaluate(expression, note: note, context: context, depth: depth + 1, visiting: visiting.union([name]))
        }
        if text == "file.name" { return .string(note.url.deletingPathExtension().lastPathComponent) }
        if text == "file.size" { return .number(Double(note.fileSize)) }
        if text == "file.ctime" { return note.created.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null }
        if text == "file.mtime" { return note.modified.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null }
        if text == "file.ext" { return .string(note.url.pathExtension) }
        if text == "file.path" { return .string(MarkdownKnowledge.relativePath(note.url, to: context.root)) }
        if text == "file.folder" {
            let folder = note.url.deletingLastPathComponent()
            return .string(folder == context.root ? "" : MarkdownKnowledge.relativePath(folder, to: context.root))
        }
        if text == "file.tags" { return .array(note.tags.map(CanvasValue.string)) }
        if text == "file.links" { return .array(note.links.filter { !$0.isEmbed }.map { .string($0.target) }) }
        if text == "file.embeds" { return .array(note.links.filter(\.isEmbed).map { .string($0.target) }) }
        if text == "file.properties" { return .object(note.values) }
        if text == "this.file.name" { return .string(context.url.deletingPathExtension().lastPathComponent) }
        if text == "this.file.path" { return .string(MarkdownKnowledge.relativePath(context.url, to: context.root)) }
        if text == "this.file.ext" { return .string(context.url.pathExtension) }
        if text == "this.file.folder" {
            let folder = context.url.deletingLastPathComponent()
            return .string(folder == context.root ? "" : MarkdownKnowledge.relativePath(folder, to: context.root))
        }
        if text.hasPrefix("this."), let current = context.currentNote {
            return try evaluate(String(text.dropFirst(5)), note: current, context: context, depth: depth + 1, visiting: visiting)
        }
        if text.hasPrefix("file.") || text.hasPrefix("this.") { throw failure(text) }
        if text.hasPrefix("note.") { text = String(text.dropFirst(5)) }
        guard MarkdownKnowledge.matches("^[\\p{L}_][\\p{L}\\p{N}_-]*(?:\\.[\\p{L}_][\\p{L}\\p{N}_-]*)*$", in: text).first != nil else { throw failure(text) }
        let path = text.split(separator: ".").map(String.init)
        var value = note.values[path[0]] ?? .null
        for key in path.dropFirst() { value = value.object?[key] ?? .null }
        return value
    }

    static func matches(_ filter: CanvasValue?, note: NoteKnowledge, context: BaseContext, depth: Int = 0) throws -> Bool {
        guard depth < 40 else { throw failure("filters") }
        guard let filter else { return true }
        if let expression = filter.string { return truthy(try evaluate(expression, note: note, context: context)) }
        guard let object = filter.object, object.count == 1 else { throw failure("filters") }
        if let values = object["and"]?.array { return try values.allSatisfy { try matches($0, note: note, context: context, depth: depth + 1) } }
        if let values = object["or"]?.array { return try values.contains { try matches($0, note: note, context: context, depth: depth + 1) } }
        if let values = object["not"]?.array { return try !values.contains { try matches($0, note: note, context: context, depth: depth + 1) } }
        throw failure("filters")
    }

    private static func failure(_ expression: String) -> VaultAccessError {
        .readFailed(String(localized: "Unsupported or invalid base expression: \(expression)"))
    }
    private static func encloses(_ text: String) -> Bool {
        let chars = Array(text)
        var depth = 0; var quote: Character?; var escaped = false
        for i in chars.indices {
            let char = chars[i]
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if let q = quote { if char == q { quote = nil }; continue }
            if char == "\"" || char == "'" { quote = char; continue }
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1; if depth == 0 { return i == chars.count - 1 } }
        }
        return false
    }
    private static func split(_ text: String, operations: [String]) -> (String, String, String)? {
        let chars = Array(text); var depth = 0; var quote: Character?; var escaped = false
        var result: (String, String, String)?
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if escaped { escaped = false; i += 1; continue }
            if char == "\\" { escaped = true; i += 1; continue }
            if let q = quote { if char == q { quote = nil }; i += 1; continue }
            if char == "\"" || char == "'" { quote = char; i += 1; continue }
            if char == "(" || char == "[" { depth += 1 }
            if char == ")" || char == "]" { depth -= 1 }
            if depth == 0, i > 0 {
                if let operation = operations.first(where: { i + $0.count <= chars.count && String(chars[i..<(i + $0.count)]) == $0 }) {
                    if operation == "+" || operation == "-" {
                        let previous = chars[..<i].last(where: { !$0.isWhitespace })
                        let exponent = i >= 2 && (chars[i - 1] == "e" || chars[i - 1] == "E") && chars[i - 2].isNumber
                        if previous == nil || previous.map({ "+-*/%(,=!<>&|".contains($0) }) == true || exponent {
                            i += 1; continue
                        }
                    }
                    let left = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                    let right = String(chars[(i + operation.count)...]).trimmingCharacters(in: .whitespaces)
                    if !left.isEmpty, !right.isEmpty { result = (left, operation, right) }
                    i += operation.count; continue
                }
            }
            i += 1
        }
        return result
    }
    private static func arguments(_ text: String) -> [String] {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var values: [String] = []; var remaining = text
        while let item = split(remaining, operations: [","]) {
            values.insert(item.2, at: 0); remaining = item.0
        }
        values.insert(remaining, at: 0); return values
    }
}

struct NoteBase: Sendable {
    let data: [String: CanvasValue]
    var views: [[String: CanvasValue]] { (data["views"]?.array ?? []).compactMap(\.object) }
    init(_ text: String) throws {
        guard text.utf8.count < 128 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        data = try NoteProperties.parse(text)
        guard !views.isEmpty else { throw VaultAccessError.readFailed(String(localized: "The base must define at least one view.")) }
    }
    func rows(view: Int, notes: [NoteKnowledge], root: URL, url: URL, aliases: [String: [URL]]) throws -> [(NoteKnowledge, [String: CanvasValue])] {
        guard views.indices.contains(view) else { return [] }
        let chosen = views[view]
        guard ["table", "list", "cards"].contains(chosen["type"]?.string ?? "table") else {
            throw VaultAccessError.readFailed(String(localized: "This base view type is not supported."))
        }
        let context = BaseContext(root: root, url: url, lookup: NoteLinkResolver(root: root, files: notes.map(\.url), aliases: aliases),
                                  formulas: data["formulas"]?.object ?? [:], currentNote: notes.first { $0.url == url })
        let columns = chosen["order"]?.array?.compactMap(\.string) ?? ["file.name"]
        var sorts = chosen["sort"]?.array?.compactMap(\.object) ?? []
        if let group = chosen["groupBy"]?.object { sorts.insert(group, at: 0) }
        let needed = Set(columns + sorts.compactMap { $0["property"]?.string })
        var rows: [(NoteKnowledge, [String: CanvasValue])] = []
        for note in notes {
            if Task.isCancelled { return [] }
            guard try BaseExpression.matches(data["filters"], note: note, context: context),
                  try BaseExpression.matches(chosen["filters"], note: note, context: context) else { continue }
            var values: [String: CanvasValue] = [:]
            for column in needed { values[column] = try BaseExpression.evaluate(column, note: note, context: context) }
            rows.append((note, values))
        }
        rows.sort {
            for sort in sorts {
                guard let property = sort["property"]?.string else { continue }
                let result = BaseExpression.compare($0.1[property] ?? .null, $1.1[property] ?? .null)
                if result != .orderedSame { return result == (sort["direction"]?.string == "DESC" ? .orderedDescending : .orderedAscending) }
            }
            return $0.0.url.path.localizedStandardCompare($1.0.url.path) == .orderedAscending
        }
        if let limit = chosen["limit"]?.number {
            guard limit.isFinite, limit >= 0 else { throw VaultAccessError.readFailed(String(localized: "Invalid base row limit.")) }
            return Array(rows.prefix(Int(min(limit, Double(rows.count)))))
        }
        return rows
    }
}
