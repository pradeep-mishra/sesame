import Foundation

public enum FileGateError: Error {
    case cannotOpen
    case notRegularFile
}

/// The one place that opens a file of the person's: read-only, never through a link, regular files only.
public enum FileGate {
    public static func read(_ file: Admitted) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FileGateError.cannotOpen }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw FileGateError.notRegularFile
        }
        return try handle.readToEnd() ?? Data()
    }
}
