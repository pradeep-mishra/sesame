import Foundation
import Testing
@testable import Sesame

private func ctWord(_ action: OpenAction) -> String {
    switch action {
    case .defaultApp: return "defaultApp"
    case .preview: return "preview"
    case .quickTime: return "quickTime"
    }
}

private func ctURL(_ action: OpenAction) -> URL {
    switch action {
    case .defaultApp(let url): return url
    case .preview(let url, _): return url
    case .quickTime(let url, _): return url
    }
}

extension ModelDownloadTests.CodeTextTests {

    @MainActor
    @Test(arguments: [Int?.none, 12, 0, 3_000])
    func aCodeFileOpensInTheDefaultAppWhateverTheSpotAndNeverAsAVscodeURL(_ spot: Int?) {
        for path in ["/Users/test/My Code/api client.swift", "/Users/test/Code/a#b.py", "/tmp/a.swift"] {
            let action = Opener.action(kind: "code", path: path, spot: spot)
            #expect(action == .defaultApp(URL(fileURLWithPath: path)), "\(path) at \(String(describing: spot)): \(action)")
            #expect(ctWord(action) == "defaultApp")
            #expect(ctURL(action).scheme != "vscode" && !ctURL(action).absoluteString.contains("vscode"), "got \(ctURL(action))")
        }
    }
}
