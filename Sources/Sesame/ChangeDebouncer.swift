import Foundation

/// One changed item reported by the file events (design sections 3 and 8). `modified` is its modified time read when the
/// event was delivered, nil when the item is gone (a delete, or the old name after a rename).
struct ChangeEvent: Equatable, Sendable {
    var path: String
    var modified: Date?
}

/// Paths as the file system spells them. FSEvents reports real paths (`/private/var/...` for a folder the person's
/// settings spell `/var/...`), so folders and events are compared as real paths. `settings.json` keeps its own spelling.
enum RealPath {
    /// `realpath(3)` of the path; for a path that does not exist (an unplugged drive), resolved as far as it exists and
    /// otherwise kept as written. A trailing slash is dropped.
    static func resolve(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var rest: [Substring] = []
        var head = Substring(path)
        while true {
            if let resolved = realpath(String(head.isEmpty ? "/" : head), nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.reversed().joined(separator: "/")
            }
            guard let slash = head.lastIndex(of: "/"), slash != head.startIndex || head.count > 1 else { return path }
            rest.append(head[head.index(after: slash)...])
            head = head[..<slash]
        }
    }
}

/// Turns a stream of change events into at most one "sync needed" request. It has no clock: every call that depends on
/// time takes `now`. A request is due 2 s after the last kept event, and never later than 30 s after the first event of
/// the request (a file written every second must not hold a sync back for ever). A modified time that lies after the
/// event's arrival counts as the arrival, so it never moves the date. An event outside every root is dropped; roots and
/// event paths are compared as real paths.
struct ChangeDebouncer {
    static let quiet: TimeInterval = 2
    /// The longest a request waits, counted from its first event.
    static let maximumWait: TimeInterval = 30

    /// The watched folders, as `settings.json` writes them; resolved to real paths when set.
    var roots: [String] {
        didSet { realRoots = roots.map(RealPath.resolve) }
    }
    private var realRoots: [String]
    private var firstArrival: Date?
    private var lastArrival: Date?

    init(roots: [String]) {
        self.roots = roots
        realRoots = roots.map(RealPath.resolve)
    }

    mutating func record(_ event: ChangeEvent, at now: Date) {
        guard isKept(event.path) else { return }
        if firstArrival == nil { firstArrival = now }
        lastArrival = now
    }

    /// When the pending request is due; nil while nothing is pending.
    var dueDate: Date? {
        guard let firstArrival, let lastArrival else { return nil }
        return min(lastArrival.addingTimeInterval(Self.quiet), firstArrival.addingTimeInterval(Self.maximumWait))
    }

    /// True once per request, when `now` has reached the due date; the request is then spent.
    mutating func takeDue(at now: Date) -> Bool {
        guard let due = dueDate, now >= due else { return false }
        firstArrival = nil
        lastArrival = nil
        return true
    }

    /// Under a root as written (FSEvents already gives real paths, so this is the common case), else as a real path.
    private func isKept(_ path: String) -> Bool {
        if realRoots.contains(where: { Self.isUnder(path, root: $0) }) { return true }
        let real = RealPath.resolve(path)
        return real != path && realRoots.contains(where: { Self.isUnder(real, root: $0) })
    }

    /// The root itself or anything below it, on a path component boundary.
    private static func isUnder(_ path: String, root: String) -> Bool {
        var root = root
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }
}
