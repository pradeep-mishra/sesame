import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-4-t1, tester step: the Apple Event that opens a PDF in Preview with search text (S3.4; design sections 5, 14, 15).
// Written from the t1 entry of plan-4-tasks.md (its Tests paragraph). No product source was read. Every expected value below
// is written by hand from the Apple Event registry; none is computed by the code under test.
//
// THE SHAPE THESE TESTS PIN (new API; today `PreviewJump` does not exist, so this file does not compile until it does):
//   enum PreviewJump { static func openEvent(file: URL, searchText: String?) -> NSAppleEventDescriptor }
//   It builds the event and sends nothing. The event is the "open documents" event: class `aevt` (kCoreEventClass), id `odoc`
//   (kAEOpenDocuments); addressed to the application with bundle id `com.apple.Preview` (descriptor type `bund`); the direct
//   object (`----`) holds the file URL; the `keyAESearchText` parameter (`stxt`) holds the search text trimmed of spaces and
//   cut at 500 characters, and is not there at all for nil, empty and only-spaces text.
// Nothing is sent, no app is launched, Preview is not opened.

private let aevt: OSType = 0x61657674          // 'aevt'
private let odoc: OSType = 0x6F646F63          // 'odoc'
private let bund: OSType = 0x62756E64          // 'bund'
private let directObject: AEKeyword = 0x2D2D2D2D   // '----'
private let addressAttribute: AEKeyword = 0x61646472  // 'addr'
private let searchTextKey: AEKeyword = 0x73747874    // 'stxt'

private let plainFile = URL(fileURLWithPath: "/Users/someone/Documents/lease.pdf")
private let oddFile = URL(fileURLWithPath: "/Users/someone/My Documents/Caf\u{00E9} r\u{00E9}sum\u{00E9} 2024.pdf")

private func searchText(of event: NSAppleEventDescriptor) -> String? {
    event.paramDescriptor(forKeyword: searchTextKey)?.stringValue
}

private func hasSearchText(_ event: NSAppleEventDescriptor) -> Bool {
    event.paramDescriptor(forKeyword: searchTextKey) != nil
}

/// The file the direct object names: one file URL, or a list holding it.
private func fileOfDirectObject(_ event: NSAppleEventDescriptor) -> URL? {
    guard let object = event.paramDescriptor(forKeyword: directObject) else { return nil }
    if object.descriptorType == typeAEList {
        guard object.numberOfItems == 1 else { return nil }
        return object.atIndex(1)?.fileURLValue
    }
    return object.fileURLValue
}

@Suite("PreviewJumpTests")
struct PreviewJumpTests {

    @Test("the event is the open-documents event: class aevt, id odoc")
    func eventClassAndID() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "deposit")
        #expect(event.eventClass == aevt)
        #expect(event.eventID == odoc)
    }

    @Test("the event is addressed to the bundle id com.apple.Preview")
    func addressedToPreview() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "deposit")
        let address = event.attributeDescriptor(forKeyword: addressAttribute)
        #expect(address != nil)
        #expect(address?.descriptorType == bund)
        if let address {
            #expect(String(data: address.data, encoding: .utf8) == "com.apple.Preview")
        } else {
            Issue.record("the event has no address attribute")
        }
    }

    @Test("the direct object holds the file URL")
    func directObjectHoldsFile() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "deposit")
        #expect(fileOfDirectObject(event)?.path == "/Users/someone/Documents/lease.pdf")
    }

    @Test("a file name with a space and a non-ASCII letter survives in the direct object")
    func directObjectKeepsSpaceAndNonASCII() {
        let event = PreviewJump.openEvent(file: oddFile, searchText: "deposit")
        let file = fileOfDirectObject(event)
        #expect(file?.path == "/Users/someone/My Documents/Caf\u{00E9} r\u{00E9}sum\u{00E9} 2024.pdf")
        #expect(file?.lastPathComponent == "Caf\u{00E9} r\u{00E9}sum\u{00E9} 2024.pdf")
    }

    @Test("the search text is carried as given when it is short and clean")
    func searchTextCarried() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "security deposit")
        #expect(searchText(of: event) == "security deposit")
    }

    @Test("the search text keeps a non-ASCII letter")
    func searchTextNonASCII() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "caf\u{00E9} menu")
        #expect(searchText(of: event) == "caf\u{00E9} menu")
    }

    @Test("spaces at both ends of the search text are trimmed, spaces inside stay")
    func searchTextTrimmed() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "   late fee  policy  ")
        #expect(searchText(of: event) == "late fee  policy")
    }

    @Test("a search text of exactly 500 characters is kept whole")
    func searchTextAtLimit() {
        let text = String(repeating: "a", count: 500)
        let event = PreviewJump.openEvent(file: plainFile, searchText: text)
        #expect(searchText(of: event) == text)
    }

    @Test("a search text of 501 characters is cut to 500")
    func searchTextOverLimitByOne() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: String(repeating: "a", count: 501))
        #expect(searchText(of: event) == String(repeating: "a", count: 500))
    }

    @Test("a long search text is cut at 500 characters, after trimming")
    func searchTextCutAfterTrim() {
        let text = "   " + String(repeating: "x", count: 600) + "   "
        let event = PreviewJump.openEvent(file: plainFile, searchText: text)
        #expect(searchText(of: event) == String(repeating: "x", count: 500))
    }

    @Test("the cut counts characters, not bytes: 600 accented letters become 500")
    func searchTextCutCountsCharacters() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: String(repeating: "\u{00E9}", count: 600))
        #expect(searchText(of: event) == String(repeating: "\u{00E9}", count: 500))
    }

    @Test("a nil search text leaves the parameter out")
    func searchTextNilAbsent() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: nil)
        #expect(hasSearchText(event) == false)
    }

    @Test("an empty search text leaves the parameter out")
    func searchTextEmptyAbsent() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "")
        #expect(hasSearchText(event) == false)
    }

    @Test("a search text of only spaces leaves the parameter out")
    func searchTextOnlySpacesAbsent() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: "     ")
        #expect(hasSearchText(event) == false)
    }

    @Test("without search text the event is still the open-documents event for Preview with the file")
    func eventWithoutSearchTextStillOpens() {
        let event = PreviewJump.openEvent(file: plainFile, searchText: nil)
        #expect(event.eventClass == aevt)
        #expect(event.eventID == odoc)
        if let address = event.attributeDescriptor(forKeyword: addressAttribute) {
            #expect(String(data: address.data, encoding: .utf8) == "com.apple.Preview")
        } else {
            Issue.record("the event has no address attribute")
        }
        #expect(fileOfDirectObject(event)?.path == "/Users/someone/Documents/lease.pdf")
    }
}
