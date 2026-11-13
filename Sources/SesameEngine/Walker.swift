import Foundation

/// One admitted file, with the metadata the index keeps for it.
public struct WalkedFile {
    public let path: String
    public let kind: String
    public let size: Int64
    public let mtimeNs: Int64
    public let inode: UInt64
}

public enum WalkerError: Error {
    case cannotRead
}

/// What `Walker.scan` found under a root.
public struct WalkResult {
    /// Every admitted file in a folder that could be listed.
    public let files: [WalkedFile]
    /// Folders that exist but could not be listed (a root that cannot be listed is `[root]`), each once, with nothing
    /// below it. A root that does not exist is not here: it is gone, not unreadable.
    public let unreadable: [String]
    /// Photos left out because their bytes are not on this Mac (an evicted cloud file, or a size with no blocks).
    /// They are not opened; the index keeps an existing row for each, as for an unreadable path.
    public let dataless: [String]
}

/// Lists the admitted files under a folder from metadata alone. It never opens a file, and it neither lists nor follows a link.
public enum Walker {
    public enum Mode {
        /// Every admitted kind: names, sizes and extensions.
        case count
        /// The kinds in `readerKinds`.
        case read
    }

    public static func walk(root: String, mode: Mode) throws -> [WalkedFile] {
        var found: [WalkedFile] = []
        try visit(folder: root, mode: mode, into: &found)
        return found
    }

    /// SF_DATALESS (<sys/stat.h>): the file's data is in the cloud and opening it would download it.
    private static let datalessFlag: UInt32 = 0x4000_0000

    public static func isDataless(flags: UInt32) -> Bool {
        flags & datalessFlag != 0
    }

    /// The kinds that have a reader. Read mode returns only these.
    public static let readerKinds: [String] = ["photo", "pdf", "doc", "audio", "video", "code"]

    /// `realpath(3)` of a path; the path itself when it cannot be resolved (it does not exist).
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func withoutTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// The same folders spelled by their real paths, so two spellings of one folder (`/var` and `/private/var`, or a
    /// symlink) compare equal.
    public static func canonical(_ folders: [HelperFolder]) -> [HelperFolder] {
        folders.map { HelperFolder(path: realPath($0.path), code: $0.code) }
    }

    /// Like `walk`, but it never throws: a folder it cannot list is reported in `unreadable` and the rest is still
    /// walked. Read mode asks `Rules.admit(path:picks:)` about every file (`picks` defaults to the root, not ticked)
    /// and returns only kinds in `readerKinds`; a hidden, `Caches` or `.app` folder is never listed. A photo that is
    /// dataless (`flags` of its path, `st_flags` of the file by default) or has a size and no blocks is left out and
    /// listed in `dataless`. Picks and the root are compared by their real paths, but the paths returned keep the
    /// spelling of `root`. In read mode a folder holding a `.git` entry is a repo: `repoFiles` is asked once for its
    /// repo-relative file list (git's by default), only those files are returned, and a repo it answers nil for is
    /// skipped and listed in `unreadable`. A repo below a vendored folder of another repo, or in a folder the outer
    /// repo's git does not list, is left out. A root that lies inside another pick which is, or lies in, a repo gets
    /// that repo's rules too. Count mode never asks.
    public static func scan(
        root: String, mode: Mode, picks: [HelperFolder]? = nil, flags: ((String) -> UInt32)? = nil,
        repoFiles: (String) -> Set<String>? = { GitFiles.list(repo: $0, git: GitFiles.systemGit) }
    ) -> WalkResult {
        var result = ScanState()
        // A root written with a trailing slash would put `//` in every path; `/` itself stays as it is.
        let root = withoutTrailingSlashes(root)
        let picks = picks ?? [HelperFolder(path: root, code: false)]
        let realPicks = canonical(picks)
        let realRoot = realPath(root)
        var scope: Repo?
        if mode == .read {
            switch enclosingScope(root: root, realRoot: realRoot, realPicks: realPicks, repoFiles: repoFiles) {
            case .none:
                break
            case .empty:
                return WalkResult(files: [], unreadable: [], dataless: [])
            case .unreadable:
                return WalkResult(files: [], unreadable: [root], dataless: [])
            case let .repo(found):
                scope = found
            }
        }
        scanFolder(
            root, real: realRoot, isRoot: true, mode: mode, picks: realPicks, flags: flags, repoFiles: repoFiles,
            repo: scope, into: &result)
        return WalkResult(files: result.files, unreadable: result.unreadable, dataless: result.dataless)
    }

    private enum Enclosing {
        case none
        /// Nothing under the root may be read: it lies below a vendored folder, or in a folder an outer repo ignores.
        case empty
        /// An enclosing repo's git cannot answer.
        case unreadable
        case repo(Repo)
    }

    private static func hasMarker(_ folder: String) -> Bool {
        var info = stat()
        return lstat((folder == "/" ? "" : folder) + "/.git", &info) == 0
    }

    private static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    /// The repos (folders holding `.git`, real paths, outermost first) strictly above `realRoot` and at or below a pick
    /// that holds it. A lone pick inside a repo has none: the repo is above the pick.
    private static func enclosingRepos(realRoot: String, realPicks: [HelperFolder]) -> [String] {
        var found = Set<String>()
        for pick in realPicks {
            let base = pick.path.hasSuffix("/") ? String(pick.path.dropLast()) : pick.path
            guard realRoot.hasPrefix(base + "/") else { continue }
            var folder = parent(realRoot)
            while true {
                if hasMarker(folder) { found.insert(folder) }
                if folder == base || folder == "/" { break }
                let next = parent(folder)
                if next == folder || next.count < base.count { break }
                folder = next
            }
        }
        return found.sorted { $0.count < $1.count }
    }

    /// `path` below `folder`, as a relative path with no leading slash (`path` itself when `folder` is `/`).
    private static func relative(_ path: String, below folder: String) -> String {
        String(path.dropFirst(folder == "/" ? 1 : folder.count + 1))
    }

    private static func enclosingScope(
        root: String, realRoot: String, realPicks: [HelperFolder], repoFiles: (String) -> Set<String>?
    ) -> Enclosing {
        var info = stat()
        // `stat`, not `lstat`: a pick may be a link to a folder, and the walk follows it.
        guard stat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .none }
        let chain = enclosingRepos(realRoot: realRoot, realPicks: realPicks)
        guard let outermost = chain.first, let nearest = chain.last else { return .none }
        // A vendored folder anywhere below the outermost repo leaves out everything below it.
        if relative(realRoot, below: outermost).split(separator: "/").contains(where: { Rules.isVendoredFolderName(String($0)) }) {
            return .empty
        }
        var lists: [Set<String>] = []
        for folder in chain {
            guard let files = repoFiles(folder) else { return .unreadable }
            lists.append(files)
        }
        // Each repo below another one must be a folder the one above lists, and so must the root when it is a repo.
        var inner = Array(chain.dropFirst())
        if hasMarker(realRoot), realRoot != nearest { inner.append(realRoot) }
        for (index, folder) in inner.enumerated() {
            let key = relative(folder, below: chain[index])
            if !(lists[index].contains(key + "/") || lists[index].contains(key)) { return .empty }
        }
        return .repo(Repo(prefix: root + "/", base: relative(realRoot, below: nearest) + "/", files: lists[lists.count - 1]))
    }

    private struct ScanState {
        var files: [WalkedFile] = []
        var unreadable: [String] = []
        var dataless: [String] = []
    }

    private static func walked(_ path: String, _ kind: String, _ info: stat) -> WalkedFile {
        WalkedFile(
            path: path,
            kind: kind,
            size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
    }

    /// Folders `Rules` never admits a file from, so read mode does not list them.
    private static func isLeftOutFolder(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Caches" || name.lowercased().hasSuffix(".app")
    }

    /// The repo a folder is in (its nearest `.git`) and the files git lists for it. `prefix` is the walked spelling of a
    /// folder and `base` the repo-relative path of that folder, so a walked path maps to a name in git's list.
    private struct Repo {
        let prefix: String
        let base: String
        let files: Set<String>

        private func listed(_ name: String) -> Bool {
            files.contains(name) || files.contains(name.precomposedStringWithCanonicalMapping)
        }

        func lists(_ path: String) -> Bool { listed(base + String(path.dropFirst(prefix.count))) }

        /// A nested repo's folder is listed as `name/` (or `name` for a submodule).
        func listsFolder(_ path: String) -> Bool {
            let name = base + String(path.dropFirst(prefix.count))
            return listed(name + "/") || listed(name)
        }
    }

    private static func scanFolder(
        _ folder: String, real: String, isRoot: Bool, mode: Mode, picks: [HelperFolder], flags: ((String) -> UInt32)?,
        repoFiles: (String) -> Set<String>?, repo: Repo?, into result: inout ScanState
    ) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            // A subfolder was a folder a moment ago; a root counts only when it is a folder now (a missing root is gone).
            var info = stat()
            if !isRoot || (lstat(folder, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR) { result.unreadable.append(folder) }
            return
        }
        var repo = repo
        if mode == .read, hasMarker(folder) {
            guard let files = repoFiles(folder) else {
                result.unreadable.append(folder)
                return
            }
            repo = Repo(prefix: folder + "/", base: "", files: files)
        }
        for name in names {
            let path = (folder == "/" ? "" : folder) + "/" + name
            let realPathOfFile = (real == "/" ? "" : real) + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                if mode == .read {
                    if isLeftOutFolder(name) { continue }
                    if let repo {
                        // Inside a repo: a vendored folder leaves out all below it, nested repos too, and a nested repo
                        // in a folder this repo's git does not list (it is ignored) is not entered.
                        if Rules.isVendoredFolderName(name) { continue }
                        if hasMarker(path), !repo.listsFolder(path) { continue }
                    }
                }
                scanFolder(
                    path, real: realPathOfFile, isRoot: false, mode: mode, picks: picks, flags: flags,
                    repoFiles: repoFiles, repo: repo, into: &result)
            } else if let repo, !repo.lists(path) {
                continue
            } else if mode == .count {
                if let admitted = Rules.admit(path: path, stat: info) { result.files.append(walked(path, admitted.kind, info)) }
            } else if let admitted = Rules.admit(path: realPathOfFile, picks: picks) {
                guard readerKinds.contains(admitted.kind) else { continue }
                if isDataless(flags: flags?(path) ?? info.st_flags) { result.dataless.append(path) } else {
                    result.files.append(walked(path, admitted.kind, info))
                }
            } else if info.st_size > 0 && info.st_blocks == 0 || isDataless(flags: info.st_flags),
                let named = Rules.admit(path: path, stat: info), readerKinds.contains(named.kind)
            {
                // `Rules` never admits a cloud-only stand-in; set it aside so an existing row for it stays.
                result.dataless.append(path)
            }
        }
    }

    private static func visit(folder: String, mode: Mode, into found: inout [WalkedFile]) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            throw WalkerError.cannotRead
        }
        for name in names {
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try visit(folder: path, mode: mode, into: &found)
            } else if let admitted = Rules.admit(path: path, stat: info),
                mode == .count || (readerKinds.contains(admitted.kind) && admitted.kind != "code")
            {
                found.append(WalkedFile(
                    path: path,
                    kind: admitted.kind,
                    size: Int64(info.st_size),
                    mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                    inode: UInt64(info.st_ino)))
            }
        }
    }
}
