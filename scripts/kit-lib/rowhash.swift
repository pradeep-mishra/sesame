// The kit's row hasher, for kit-index.sh snapshot.
//
//   rowhash <label>      reads lines "<key><TAB><rest>" on stdin and writes
//                        "<label><TAB><key><TAB><SHA-256 of the whole input line>" for each
//
// The index is read through sqlite3, which prints every value as hex, so a line is plain text
// whatever the row holds (vectors and OCR text with newlines included).
// Exit codes: 0 done; 2 usage.
import CryptoKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 else {
    FileHandle.standardError.write("usage: rowhash <label>\n".data(using: .utf8)!)
    exit(2)
}
let label = args[0]

var output = ""
while let line = readLine(strippingNewline: true) {
    let key = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let digest = SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    output += "\(label)\t\(key)\t\(digest)\n"
    if output.utf8.count > 1 << 20 {
        FileHandle.standardOutput.write(output.data(using: .utf8)!)
        output = ""
    }
}
FileHandle.standardOutput.write(output.data(using: .utf8)!)
