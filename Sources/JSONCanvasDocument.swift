import Foundation

/// Retain unknown JSON fields and node types when editing an Obsidian canvas.
enum CanvasValue: Codable, Sendable, Equatable {
    case object([String: CanvasValue]), array([CanvasValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count < 64 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Document nesting exceeds 64 levels."))
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) {
            guard number.isFinite else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Numbers must be finite.")) }
            self = .number(number)
        }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([CanvasValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: CanvasValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var number: Double? { if case let .number(value) = self { return value }; return nil }
    var object: [String: CanvasValue]? { if case let .object(value) = self { return value }; return nil }
    var array: [CanvasValue]? { if case let .array(value) = self { return value }; return nil }
}

struct CanvasNode: Identifiable, Sendable {
    let data: [String: CanvasValue]
    var id: String { data["id"]?.string ?? "" }
    var type: String { data["type"]?.string ?? "text" }
    var x: Double { data["x"]?.number ?? 0 }
    var y: Double { data["y"]?.number ?? 0 }
    var width: Double { data["width"]?.number ?? 250 }
    var height: Double { data["height"]?.number ?? 180 }
    var contentKey: String { ["file": "file", "link": "url", "group": "label"][type] ?? "text" }
    var content: String { data[contentKey]?.string ?? "" }
}

struct JSONCanvasDocument: Sendable {
    var data: [String: CanvasValue]
    var nodes: [CanvasNode] { (data["nodes"]?.array ?? []).compactMap { $0.object.map(CanvasNode.init) } }
    var edges: [[String: CanvasValue]] { (data["edges"]?.array ?? []).compactMap(\.object) }

    init(text: String) throws {
        data = try JSONDecoder().decode([String: CanvasValue].self, from: Data(text.utf8))
        guard data["nodes"] == nil || data["nodes"]?.array != nil,
              data["edges"] == nil || data["edges"]?.array != nil else { throw CocoaError(.fileReadCorruptFile) }
        let nodes = nodes
        guard Set(nodes.map(\.id)).count == nodes.count,
              nodes.allSatisfy({ !$0.id.isEmpty && abs($0.x) < 1_000_000 && abs($0.y) < 1_000_000
                  && $0.width > 0 && $0.height > 0 && $0.width < 10_000 && $0.height < 10_000 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func text() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(data), as: UTF8.self)
    }

    mutating func update(_ id: String, values: [String: CanvasValue]) {
        var nodes = data["nodes"]?.array ?? []
        guard let i = nodes.firstIndex(where: { $0.object?["id"]?.string == id }), var object = nodes[i].object else { return }
        object.merge(values) { _, new in new }
        nodes[i] = .object(object)
        data["nodes"] = .array(nodes)
    }

    mutating func add(type: String, content: String, x: Double, y: Double) {
        let key = ["file": "file", "link": "url", "group": "label"][type] ?? "text"
        let node: [String: CanvasValue] = ["id": .string(UUID().uuidString), "type": .string(type),
            "x": .number(x), "y": .number(y), "width": .number(250), "height": .number(180), key: .string(content)]
        var nodes = data["nodes"]?.array ?? []
        nodes.append(.object(node)); data["nodes"] = .array(nodes)
    }

    mutating func connect(from: String, to: String) {
        guard from != to, nodes.contains(where: { $0.id == from }), nodes.contains(where: { $0.id == to }) else { return }
        var edges = data["edges"]?.array ?? []
        edges.append(.object(["id": .string(UUID().uuidString), "fromNode": .string(from), "toNode": .string(to)]))
        data["edges"] = .array(edges)
    }

    mutating func remove(_ id: String) {
        data["nodes"] = .array((data["nodes"]?.array ?? []).filter { $0.object?["id"]?.string != id })
        data["edges"] = .array((data["edges"]?.array ?? []).filter {
            $0.object?["fromNode"]?.string != id && $0.object?["toNode"]?.string != id
        })
    }

    mutating func rewriteLinks(using mutation: VaultLinkMutation, at url: URL) {
        let move = VaultDocumentMove(source: mutation.source, destination: mutation.destination)
        for node in nodes {
            if node.type == "file" || node.type == "group" {
                let key = node.type == "file" ? "file" : "background"
                guard let path = node.data[key]?.string else { continue }
                let target = mutation.root.appendingPathComponent(path).standardizedFileURL
                guard mutation.files.contains(target), move.relocated(target) != target else { continue }
                update(node.id, values: [key: .string(MarkdownKnowledge.relativePath(move.relocated(target), to: mutation.root))])
            } else if node.type == "text" {
                update(node.id, values: ["text": .string(mutation.rewrite(node.content, at: url))])
            }
        }
    }
}
