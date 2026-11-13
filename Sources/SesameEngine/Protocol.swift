import Foundation

// The Helper protocol, written once as code (plan-1-tasks.md, Conventions). One JSON object per line.
// Commands go to a helper's stdin (field `cmd`); events and replies come on its stdout (field `event`).
// An unknown extra field is tolerated; a line that is not exactly one JSON object is refused.

/// One folder of the `folders` command. `code` is always false now.
public struct HelperFolder: Equatable, Sendable {
    public let path: String
    public let code: Bool

    public init(path: String, code: Bool) {
        self.path = path
        self.code = code
    }
}

/// App to helper.
public enum HelperCommand: Equatable, Sendable {
    case prewarm
    case embed(id: Int, text: String, role: EmbedRole)
    case panel(open: Bool)
    case folders([HelperFolder])
    case reset
    case preview(ticket: Int, file: String, passage: Int?, query: String)
}

public enum PreviewStatus: String, Equatable, Sendable {
    case ok, changed, gone
}

/// The reply to `preview`. For `gone`, `png`, `size` and `mtime` are nil (null on the wire). A PDF reply adds `page`,
/// `pageCount` and `locator` ("Page 7 of 12"); a document reply adds `text` (the passage in context) and `marks` (flat
/// start, end UTF-16 offsets into `text`). An audio or video reply adds `locator` ("Opens at 02:10") and `seconds` (the spot in
/// whole seconds); an audio reply's `text` is the spoken words. A photo reply has none of them, and none is written to its line.
public struct PreviewReply: Equatable, Sendable {
    public let ticket: Int
    public let status: PreviewStatus
    public let png: String?
    public let name: String
    public let kind: String
    public let size: Int?
    public let mtime: Int?
    public let page: Int?
    public let pageCount: Int?
    public let locator: String?
    public let text: String?
    public let marks: [Int]
    public let seconds: Int?
    public let line: Int?
    public let firstLine: Int?

    public init(
        ticket: Int, status: PreviewStatus, png: String?, name: String, kind: String, size: Int?, mtime: Int?,
        page: Int? = nil, pageCount: Int? = nil, locator: String? = nil, text: String? = nil, marks: [Int] = [],
        seconds: Int? = nil, line: Int? = nil, firstLine: Int? = nil
    ) {
        self.ticket = ticket
        self.status = status
        self.png = png
        self.name = name
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.page = page
        self.pageCount = pageCount
        self.locator = locator
        self.text = text
        self.marks = marks
        self.seconds = seconds
        self.line = line
        self.firstLine = firstLine
    }
}

/// Helper to app.
public enum HelperEvent: Equatable, Sendable {
    case vector(id: Int, ms: Int, vec: [Float])
    case refused(id: Int, reason: String)
    case unit(size: Int)
    case preview(PreviewReply)
    case changed
    case walked
    /// `index bench`'s one line: seconds per file by kind, each a positive number.
    case bench(speeds: [String: Double])
}

public enum ProtocolError: Error, Equatable {
    case notOneObject
    case unknown(String)
    case badField(String)
}

/// The encoder and the decoder.
public enum HelperProtocol {

    // MARK: encode

    public static func line(for command: HelperCommand) throws -> String {
        switch command {
        case .prewarm:
            return try write(["cmd": "prewarm"])
        case let .embed(id, text, role):
            return try write(["cmd": "embed", "id": id, "text": text, "role": role == .query ? "query" : "document"])
        case let .panel(open):
            return try write(["cmd": "panel", "open": open])
        case let .folders(folders):
            let list = folders.map { ["path": $0.path, "code": $0.code] as [String: Any] }
            return try write(["cmd": "folders", "folders": list])
        case .reset:
            return try write(["cmd": "reset"])
        case let .preview(ticket, file, passage, query):
            return try write(["cmd": "preview", "ticket": ticket, "file": file,
                              "passage": passage.map { $0 as Any } ?? NSNull(), "query": query])
        }
    }

    public static func line(for event: HelperEvent) throws -> String {
        switch event {
        case let .vector(id, ms, vec):
            return try write(["event": "vector", "id": id, "ms": ms, "vec": vec.map { Double($0) }])
        case let .refused(id, reason):
            return try write(["event": "refused", "id": id, "reason": reason])
        case let .unit(size):
            return try write(["event": "unit", "size": size])
        case let .preview(reply):
            var object: [String: Any] = [
                "event": "preview", "ticket": reply.ticket, "status": reply.status.rawValue,
                "png": reply.png.map { $0 as Any } ?? NSNull(), "name": reply.name, "kind": reply.kind,
                "size": reply.size.map { $0 as Any } ?? NSNull(), "mtime": reply.mtime.map { $0 as Any } ?? NSNull(),
            ]
            if let page = reply.page { object["page"] = page }
            if let pageCount = reply.pageCount { object["pageCount"] = pageCount }
            if let locator = reply.locator { object["locator"] = locator }
            if let text = reply.text { object["text"] = text }
            if !reply.marks.isEmpty { object["marks"] = reply.marks }
            if let seconds = reply.seconds { object["seconds"] = seconds }
            if let line = reply.line { object["line"] = line }
            if let firstLine = reply.firstLine { object["firstLine"] = firstLine }
            return try write(object)
        case .changed:
            return try write(["event": "changed"])
        case .walked:
            return try write(["event": "walked"])
        case let .bench(speeds):
            return try write(["event": "bench", "speeds": speeds])
        }
    }

    private static func write(_ object: [String: Any]) throws -> String {
        // `isValidJSONObject` first: a NaN or infinite number would raise an Objective-C exception.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { throw ProtocolError.badField("unencodable value") }
        return text
    }

    // MARK: decode

    public static func command(from line: String) throws -> HelperCommand {
        let object = try parse(line)
        let name = try string(object, "cmd")
        switch name {
        case "prewarm":
            return .prewarm
        case "embed":
            let role: EmbedRole
            switch try string(object, "role") {
            case "query": role = .query
            case "document": role = .document
            default: throw ProtocolError.badField("role")
            }
            return .embed(id: try int(object, "id"), text: try string(object, "text"), role: role)
        case "panel":
            return .panel(open: try bool(object, "open"))
        case "folders":
            guard let list = object["folders"] as? [Any] else { throw ProtocolError.badField("folders") }
            return .folders(try list.map { item in
                guard let folder = item as? [String: Any] else { throw ProtocolError.badField("folders") }
                return HelperFolder(path: try string(folder, "path"), code: try bool(folder, "code"))
            })
        case "reset":
            return .reset
        case "preview":
            return .preview(ticket: try int(object, "ticket"), file: try string(object, "file"),
                            passage: try optionalInt(object, "passage"), query: try string(object, "query"))
        default:
            throw ProtocolError.unknown(name)
        }
    }

    public static func event(from line: String) throws -> HelperEvent {
        let object = try parse(line)
        let name = try string(object, "event")
        switch name {
        case "vector":
            guard let numbers = object["vec"] as? [Any] else { throw ProtocolError.badField("vec") }
            let vec = try numbers.map { item -> Float in
                guard let number = item as? NSNumber, !isBoolean(number) else { throw ProtocolError.badField("vec") }
                return number.floatValue
            }
            return .vector(id: try int(object, "id"), ms: try int(object, "ms"), vec: vec)
        case "refused":
            return .refused(id: try int(object, "id"), reason: try string(object, "reason"))
        case "unit":
            return .unit(size: try int(object, "size"))
        case "preview":
            guard let status = PreviewStatus(rawValue: try string(object, "status")) else {
                throw ProtocolError.badField("status")
            }
            return .preview(PreviewReply(
                ticket: try int(object, "ticket"), status: status, png: try optionalString(object, "png"),
                name: try string(object, "name"), kind: try string(object, "kind"),
                size: try optionalInt(object, "size"), mtime: try optionalInt(object, "mtime"),
                page: try optionalInt(object, "page"), pageCount: try optionalInt(object, "pageCount"),
                locator: try optionalString(object, "locator"), text: try optionalString(object, "text"),
                marks: try intList(object, "marks"), seconds: try optionalInt(object, "seconds"),
                line: try optionalInt(object, "line"), firstLine: try optionalInt(object, "firstLine")))
        case "changed":
            return .changed
        case "walked":
            return .walked
        case "bench":
            guard let speeds = object["speeds"] as? [String: Any] else { throw ProtocolError.badField("speeds") }
            return .bench(speeds: try speeds.mapValues { item in
                guard let number = item as? NSNumber, !isBoolean(number), number.doubleValue > 0, number.doubleValue.isFinite
                else { throw ProtocolError.badField("speeds") }
                return number.doubleValue
            })
        default:
            throw ProtocolError.unknown(name)
        }
    }

    // MARK: reading fields

    /// One JSON object and nothing else. A raw newline can only be white space between values (inside a string it is
    /// escaped), so a line holding one is two lines, or a pretty-printed object: refused.
    private static func parse(_ line: String) throws -> [String: Any] {
        guard !line.contains("\n"), !line.contains("\r"),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        else { throw ProtocolError.notOneObject }
        return object
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw ProtocolError.badField(key) }
        return value
    }

    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ProtocolError.badField(key) }
        return text
    }

    private static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, isBoolean(number) else { throw ProtocolError.badField(key) }
        return number.boolValue
    }

    private static func int(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber, !isBoolean(number),
              let value = Int(exactly: number.doubleValue) else { throw ProtocolError.badField(key) }
        return value
    }

    /// An array of whole numbers; empty when the key is absent or null.
    private static func intList(_ object: [String: Any], _ key: String) throws -> [Int] {
        guard let value = object[key], !(value is NSNull) else { return [] }
        guard let items = value as? [Any] else { throw ProtocolError.badField(key) }
        return try items.map { item in
            guard let number = item as? NSNumber, !isBoolean(number), let whole = Int(exactly: number.doubleValue)
            else { throw ProtocolError.badField(key) }
            return whole
        }
    }

    private static func optionalInt(_ object: [String: Any], _ key: String) throws -> Int? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        return try int(object, key)
    }
}
