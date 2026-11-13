import Foundation
import SesameEngine

struct CouldNotReadList: Equatable {
    static let emptyMessage = "Nothing here. Files Sesame could not read are listed here."

    let rows: [String]

    init(files: [UnreadableFile]) {
        rows = files.map { "\($0.name), \($0.reason)" }
    }

    var emptyText: String? { rows.isEmpty ? Self.emptyMessage : nil }
}
