import Foundation

/// A path `Rules.admit` has accepted. Only `Rules.admit` can make one, so `FileGate` never opens anything else.
public struct Admitted {
    public let path: String
    public let kind: String

    init(path: String, kind: String) {
        self.path = path
        self.kind = kind
    }
}

/// What Sesame may read: the six kinds by extension, and the key and password names it never reads.
public enum Rules {
    public static let codeKindOn = false

    private static let extensionsByKind: [(kind: String, extensions: [String])] = [
        ("photo", ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]),
        ("pdf", ["pdf"]),
        ("doc", ["txt", "md", "rtf", "docx", "html", "odt"]),
        ("audio", ["mp3", "m4a", "wav", "aac", "flac"]),
        ("video", ["mp4", "mov", "m4v"]),
        ("code", ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]),
    ]

    // The one table of key and password names, compared in lowercase. A name ending in a suffix or starting with a
    // prefix is never read; the env file name is exact (`.env`, or `.env.` and anything after it), so `.environment.png`
    // is an ordinary name. `.envrc` (direnv) is refused too.
    private static let keyNameSuffixes = [".pem", ".key", ".p12", ".pfx", ".kdbx"]
    private static let keyNamePrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    private static let envFileName = ".env"
    private static let envrcFileName = ".envrc"

    private static let kindByExtension: [String: String] = {
        var table: [String: String] = [:]
        for entry in extensionsByKind {
            guard entry.kind != "code" || codeKindOn else { continue }
            for ext in entry.extensions { table[ext] = entry.kind }
        }
        return table
    }()

    /// The kind of a file extension (no dot, lowercase), or nil when Sesame does not read it.
    public static func kind(forExtension ext: String) -> String? {
        kindByExtension[ext]
    }

    /// True for a last path component that is a key or password name, whatever its extension and its letter case.
    public static func isKeyName(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        return keyNameSuffixes.contains { name.hasSuffix($0) } || keyNamePrefixes.contains { name.hasPrefix($0) }
            || name == envFileName || name.hasPrefix(envFileName + ".") || name == envrcFileName
    }

    /// The path as an `Admitted` value when it is a regular file of a supported kind and not a key name.
    public static func admit(path: String) -> Admitted? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return admit(path: path, stat: info)
    }

    // Folder names that are left out below a pick: `Caches` exactly, any `.app` bundle in any letter case, and every
    // hidden folder. Inside a repo the vendored names are left out too.
    private static let cachesFolderName = "Caches"
    private static let appBundleSuffix = ".app"
    private static let repoMarkerName = ".git"
    private static let vendoredFolderNames: Set<String> = ["node_modules", "Pods", "build", "dist", "vendor"]

    /// The path as an `Admitted` value when it is a readable file of a supported kind, held by at least one pick
    /// and not in an excluded place of it. Only the folder names below the pick root count. A repo is a folder at or
    /// below the pick root that holds an entry named `.git`; a pick inside a repo is not treated as one. A file below a
    /// vendored folder that is itself below the outermost repo is never admitted (a nested repo does not lift it). A file with a
    /// size and no blocks, or a dataless one, is a cloud-only stand-in and is never admitted.
    public static func admit(path: String, picks: [HelperFolder]) -> Admitted? {
        var info = stat()
        guard lstat(path, &info) == 0, let admitted = admit(path: path, stat: info) else { return nil }
        guard !(info.st_size > 0 && info.st_blocks == 0), !Walker.isDataless(flags: info.st_flags) else { return nil }
        for pick in picks where isAdmitted(admitted, by: pick) { return admitted }
        return nil
    }

    private static func isAdmitted(_ file: Admitted, by pick: HelperFolder) -> Bool {
        let prefix = pick.path.hasSuffix("/") ? pick.path : pick.path + "/"
        guard file.path.hasPrefix(prefix) else { return false }
        let folders = file.path.dropFirst(prefix.count).split(separator: "/").dropLast().map(String.init)
        for name in folders
        where name.hasPrefix(".") || name == cachesFolderName || name.lowercased().hasSuffix(appBundleSuffix) {
            return false
        }
        // The outermost repo at or below the pick root decides the vendored rule: a vendored folder anywhere below it
        // leaves out everything under it, a nested repo included.
        var outermost: Int?
        for depth in 0...folders.count {
            let folder = prefix + folders[..<depth].joined(separator: "/")
            var marker = stat()
            if lstat(folder + "/" + repoMarkerName, &marker) == 0 {
                outermost = depth
                break
            }
        }
        guard let outermost else { return true }
        return !folders[outermost...].contains(where: { vendoredFolderNames.contains($0) })
    }

    /// True for a folder name `Rules` treats as vendored inside a repo.
    static func isVendoredFolderName(_ name: String) -> Bool { vendoredFolderNames.contains(name) }

    /// The same decision for a path whose `lstat` the caller already holds.
    static func admit(path: String, stat info: stat) -> Admitted? {
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        let name = (path as NSString).lastPathComponent
        guard !isKeyName(name) else { return nil }
        guard let kind = kind(forExtension: (name as NSString).pathExtension.lowercased()) else { return nil }
        return Admitted(path: path, kind: kind)
    }
}
