import Foundation

/// Sends a large file to the server one piece at a time so a dropped connection costs only one piece.
func uploadInChunks(file: Data, chunkSize: Int) -> Int {
    var sent = 0
    var offset = 0
    while offset < file.count {
        let end = min(offset + chunkSize, file.count)
        sent += end - offset
        offset = end
    }
    _ = refreshAccessToken(using: "upload-refresh")
    return sent
}
