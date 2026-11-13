import AppKit
import Darwin

/// Loads the preview PNG the `index` helper wrote (design sections 9.2 and 12). The one place the app reads such a
/// file, and the one place it deletes one. It accepts only a regular PNG file directly inside a folder named
/// `Sesame-<digits>` that is directly inside `$TMPDIR`; the digits are the helper's process id, not the app's. The
/// picture is made from the bytes with `NSImage(data:)`, so it still draws after the file is deleted, and the
/// file is deleted once it has loaded. Anything else is refused and left alone.
enum ScratchPNG {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let folderPrefix = "Sesame-"
    private static let largestFile = 64 * 1024 * 1024

    static func load(path: String) -> NSImage? {
        guard isInScratchFolder(path), let data = readRegularFile(path), data.starts(with: signature),
              let image = NSImage(data: data), let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        unlink(path)
        return image
    }

    private static func isInScratchFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let digits = folder.lastPathComponent.dropFirst(folderPrefix.count)
        guard folder.lastPathComponent.hasPrefix(folderPrefix), !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let real = folder.resolvingSymlinksInPath()
        return real.lastPathComponent == folder.lastPathComponent
            && real.deletingLastPathComponent().path == URL(fileURLWithPath: tmp).resolvingSymlinksInPath().path
    }

    /// A link is refused (`lstat` does not follow it), and the file opened is the one `lstat` saw: same device and
    /// inode, so a link put in its place after the check is not read.
    private static func readRegularFile(_ path: String) -> Data? {
        var named = stat()
        guard lstat(path, &named) == 0, (named.st_mode & S_IFMT) == S_IFREG, named.st_size <= largestFile else {
            return nil
        }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            return nil
        }
        return try? handle.readToEnd()
    }
}
