/// What a preview request was asked for: the file, the passage the list named, the file's kind and the typed text.
/// The pane asks the helper again only when this changes in a way the preview shows. A PDF or document preview shows
/// the passage's page or window with the typed words marked, so its path, passage and text all count; a photo shows the
/// picture, so only its path counts. `kind` is "" until a reply has said what the file is, which counts as a document.
struct PreviewRequestKey: Equatable {
    let path: String
    let passageID: Int64?
    let kind: String
    let query: String

    init(path: String, passageID: Int64?, kind: String, query: String) {
        self.path = path
        self.passageID = passageID
        self.kind = kind
        self.query = query
    }

    func needsRequest(after previous: PreviewRequestKey?) -> Bool {
        guard let previous else { return true }
        if path != previous.path || kind != previous.kind { return true }
        if kind == "photo" { return false }
        return passageID != previous.passageID || query != previous.query
    }
}
