import Foundation

/// The contents of `settings.json` (design section 1). JSON keys are the property names.
public struct Settings: Codable, Equatable, Sendable {
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var code: Bool
        /// What the helper reads.
        public var reading: Bool
        /// What the person has ticked. It differs from `reading` while a tick waits for Start indexing.
        /// Stored only when it differs from `reading`; a missing key reads as `reading`.
        public var ticked: Bool

        public init(path: String, code: Bool, reading: Bool, ticked: Bool? = nil) {
            self.path = path
            self.code = code
            self.reading = reading
            self.ticked = ticked ?? reading
        }

        private enum CodingKeys: String, CodingKey { case path, code, reading, ticked }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            code = try values.decode(Bool.self, forKey: .code)
            reading = try values.decode(Bool.self, forKey: .reading)
            ticked = try values.decodeIfPresent(Bool.self, forKey: .ticked) ?? reading
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(path, forKey: .path)
            try values.encode(code, forKey: .code)
            try values.encode(reading, forKey: .reading)
            if ticked != reading { try values.encode(ticked, forKey: .ticked) }
        }
    }

    public struct OpenWith: Codable, Equatable, Sendable {
        public var pdf: String
        public var media: String
        public var code: String

        public init(pdf: String, media: String, code: String) {
            self.pdf = pdf
            self.media = media
            self.code = code
        }
    }

    public var version: Int
    public var startPressed: Bool
    public var indexDeleted: Bool
    public var folders: [Folder]
    public var codeSearchOn: Bool
    public var kindsOn: [String: Bool]
    public var hotkey: String
    public var openWith: OpenWith
    /// Seconds per file, by kind.
    public var speeds: [String: Double]
    public var loginDefaultApplied: Bool
    /// True once Finish or Start closed the setup window for good. Stored only when true.
    public var setupFinished: Bool

    public init(
        version: Int = 1, startPressed: Bool = false, indexDeleted: Bool = false, folders: [Folder] = [],
        codeSearchOn: Bool = false, kindsOn: [String: Bool] = ["photo": true],
        hotkey: String = "ctrl+opt+space", openWith: OpenWith = OpenWith(pdf: "", media: "", code: ""),
        speeds: [String: Double] = [:], loginDefaultApplied: Bool = false, setupFinished: Bool = false
    ) {
        self.version = version
        self.startPressed = startPressed
        self.indexDeleted = indexDeleted
        self.folders = folders
        self.codeSearchOn = codeSearchOn
        self.kindsOn = kindsOn
        self.hotkey = hotkey
        self.openWith = openWith
        self.speeds = speeds
        self.loginDefaultApplied = loginDefaultApplied
        self.setupFinished = setupFinished
    }

    private enum CodingKeys: String, CodingKey {
        case version, startPressed, indexDeleted, folders, codeSearchOn, kindsOn, hotkey, openWith, speeds
        case loginDefaultApplied, setupFinished
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        startPressed = try values.decode(Bool.self, forKey: .startPressed)
        indexDeleted = try values.decode(Bool.self, forKey: .indexDeleted)
        folders = try values.decode([Folder].self, forKey: .folders)
        codeSearchOn = try values.decode(Bool.self, forKey: .codeSearchOn)
        kindsOn = try values.decode([String: Bool].self, forKey: .kindsOn)
        hotkey = try values.decode(String.self, forKey: .hotkey)
        openWith = try values.decode(OpenWith.self, forKey: .openWith)
        speeds = try values.decode([String: Double].self, forKey: .speeds)
        loginDefaultApplied = try values.decode(Bool.self, forKey: .loginDefaultApplied)
        setupFinished = try values.decodeIfPresent(Bool.self, forKey: .setupFinished) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(startPressed, forKey: .startPressed)
        try values.encode(indexDeleted, forKey: .indexDeleted)
        try values.encode(folders, forKey: .folders)
        try values.encode(codeSearchOn, forKey: .codeSearchOn)
        try values.encode(kindsOn, forKey: .kindsOn)
        try values.encode(hotkey, forKey: .hotkey)
        try values.encode(openWith, forKey: .openWith)
        try values.encode(speeds, forKey: .speeds)
        try values.encode(loginDefaultApplied, forKey: .loginDefaultApplied)
        if setupFinished { try values.encode(true, forKey: .setupFinished) }
    }
}

/// Reads and writes `settings.json` in the Sesame folder. Holds no copy: every `read()` goes to disk,
/// and every write goes through `SesameFolder.write`.
public struct SettingsFile: Sendable {
    static let name = "settings.json"

    public init() {}

    /// The stored settings, or the defaults (startPressed false, indexDeleted false) when there is no file.
    public func read() throws -> Settings {
        let path = SesameFolder.url.appendingPathComponent(Self.name)
        guard FileManager.default.fileExists(atPath: path.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: path))
    }

    public func setAsideIfCorrupt(now: Date = Date()) -> Bool {
        let path = SesameFolder.url.appendingPathComponent(Self.name)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard (try? read()) == nil else { return false }
        let moved = "\(Self.name).corrupt-\(Int(now.timeIntervalSince1970))"
        return (try? SesameFolder.rename(Self.name, to: moved)) != nil
    }

    public func write(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SesameFolder.write(encoder.encode(settings), to: Self.name)
    }
}
