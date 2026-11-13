import Foundation
import Testing
@testable import Sesame

// plan-4 review round 1, fix round, tester step: the pane's preview request key (decision logged by the controller).
// Rule: ask the helper again when the path, the passage id or the query text changes; for a photo only the path (or the kind) counts.
// Hand-written cases against `PreviewRequestKey(path:passageID:kind:query:)` and `needsRequest(after:)`.

private func key(_ path: String = "/docs/lease.pdf", passage: Int64? = 7, kind: String = "pdf", query: String = "tenant") -> PreviewRequestKey {
    PreviewRequestKey(path: path, passageID: passage, kind: kind, query: query)
}

@Suite("PreviewRequestKeyTests")
struct PreviewRequestKeyTests {

    // Every kind: nothing asked yet means ask; the same key again means do not.
    static let samples: [(kind: String, path: String)] = [
        ("photo", "/photos/receipt.jpg"), ("pdf", "/docs/lease.pdf"), ("doc", "/docs/notes.docx"),
    ]

    @Test(arguments: samples)
    func aNilPreviousKeyNeedsARequest(sample: (kind: String, path: String)) {
        #expect(key(sample.path, kind: sample.kind).needsRequest(after: nil))
    }

    @Test(arguments: samples)
    func anIdenticalKeyNeedsNoRequest(sample: (kind: String, path: String)) {
        let one = key(sample.path, kind: sample.kind)
        #expect(!one.needsRequest(after: key(sample.path, kind: sample.kind)))
    }

    @Test(arguments: samples)
    func anIdenticalKeyWithNoPassageNeedsNoRequest(sample: (kind: String, path: String)) {
        #expect(!key(sample.path, passage: nil, kind: sample.kind).needsRequest(after: key(sample.path, passage: nil, kind: sample.kind)))
    }

    // pdf and doc: path, passage id and query text each matter
    @Test(arguments: ["pdf", "doc"])
    func aDifferentPathNeedsARequest(kind: String) {
        #expect(key("/docs/b", kind: kind).needsRequest(after: key("/docs/a", kind: kind)))
    }

    @Test(arguments: ["pdf", "doc"])
    func aDifferentPassageIDNeedsARequest(kind: String) {
        #expect(key(passage: 8, kind: kind).needsRequest(after: key(passage: 7, kind: kind)))
    }

    @Test(arguments: ["pdf", "doc"])
    func aPassageIDAppearingNeedsARequest(kind: String) {
        #expect(key(passage: 7, kind: kind).needsRequest(after: key(passage: nil, kind: kind)))
    }

    @Test(arguments: ["pdf", "doc"])
    func aPassageIDGoingAwayNeedsARequest(kind: String) {
        #expect(key(passage: nil, kind: kind).needsRequest(after: key(passage: 7, kind: kind)))
    }

    @Test(arguments: ["pdf", "doc"])
    func aDifferentQueryTextNeedsARequest(kind: String) {
        #expect(key(kind: kind, query: "tenant pays").needsRequest(after: key(kind: kind, query: "tenant")))
    }

    @Test(arguments: ["pdf", "doc"])
    func aTrailingSpaceInTheQueryNeedsARequest(kind: String) {
        #expect(key(kind: kind, query: "tenant ").needsRequest(after: key(kind: kind, query: "tenant")))
    }

    @Test(arguments: ["pdf", "doc"])
    func aLeadingSpaceInTheQueryNeedsARequest(kind: String) {
        #expect(key(kind: kind, query: " tenant").needsRequest(after: key(kind: kind, query: "tenant")))
    }

    // photo: only the path (and the kind) count
    @Test func aDifferentPhotoPathNeedsARequest() {
        #expect(key("/photos/b.jpg", kind: "photo").needsRequest(after: key("/photos/a.jpg", kind: "photo")))
    }

    @Test func aDifferentKindOnTheSamePathNeedsARequest() {
        #expect(key("/photos/a.jpg", kind: "photo").needsRequest(after: key("/photos/a.jpg", kind: "pdf")))
        #expect(key("/docs/a", kind: "doc").needsRequest(after: key("/docs/a", kind: "pdf")))
    }

    @Test func aPdfThenAPhotoOfTheSamePathNeedsARequest() {
        #expect(key("/x/same", passage: 7, kind: "photo", query: "tenant").needsRequest(after: key("/x/same", passage: 7, kind: "pdf", query: "tenant")))
    }

    @Test func aDifferentQueryTextAloneDoesNotNeedARequestForAPhoto() {
        #expect(!key("/photos/a.jpg", passage: nil, kind: "photo", query: "kettle price").needsRequest(
            after: key("/photos/a.jpg", passage: nil, kind: "photo", query: "kettle")))
    }

    @Test func aDifferentPassageIDAloneDoesNotNeedARequestForAPhoto() {
        #expect(!key("/photos/a.jpg", passage: 9, kind: "photo").needsRequest(after: key("/photos/a.jpg", passage: 3, kind: "photo")))
        #expect(!key("/photos/a.jpg", passage: 9, kind: "photo").needsRequest(after: key("/photos/a.jpg", passage: nil, kind: "photo")))
    }
}
