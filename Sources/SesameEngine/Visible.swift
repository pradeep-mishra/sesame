import Foundation

/// The one query-time filter (design section 3): a result shows only if its path is under a ticked folder,
/// code shows only if a code-ticked folder holds it, and a kind switched off is hidden.
public struct Visible: Sendable {
    private let folders: [Settings.Folder]
    private let codeSearchOn: Bool
    private let kindsOn: [String: Bool]

    public init(folders: [Settings.Folder], codeSearchOn: Bool, kindsOn: [String: Bool]) {
        self.folders = folders
        self.codeSearchOn = codeSearchOn
        self.kindsOn = kindsOn
    }

    public func allows(path: String, kind: String) -> Bool {
        if kindsOn[kind] == false { return false }
        if kind == "code" && !Rules.codeKindOn { return false }
        return folders.contains { Self.holds($0.path, path) }
    }

    /// Under means a prefix that ends at a `/`, so `/x/PicturesOld/a` is not under `/x/Pictures`.
    private static func holds(_ folder: String, _ path: String) -> Bool {
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(base)
    }
}
