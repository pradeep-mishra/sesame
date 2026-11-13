import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t37, tester step. Written from the t37 entry, spec S1 ("Enter opens the photo in the default image app,
// Command+Enter reveals it in Finder. Command+C copies the selected file when no text in the box is selected ... If
// the selected file has gone when Enter, Command+Enter or Command+C is pressed, the panel says 'That file is no
// longer there', drops the result, selects the next one"), design section 5 (Opener table, "Opens in <app>") and
// section 9.2 (ScratchPNG: "path must be under $TMPDIR/Sesame-<pid>, decoded with NSImage(data:)", "may only delete
// the preview PNG it loaded"), and the person's HARD RULE (no app launch: red through `swift test` only). No product
// source read. Every expected text and value below is written by hand from those documents or built by the test.
//
// SHAPES these tests pin. The design names `ScratchPNG`, `Opener`, `Pane`, `Panel` and `ResultList` and fixes no
// signatures, so each of these is my pick (guess). If one is wrong, ask for a test change; do not guess.
//
//  1. ScratchPNG (the task's Tests: paragraph).
//       enum ScratchPNG { static func load(path: String) -> NSImage? }
//     nil means refused. A PNG file is accepted only when it lies directly inside a folder named `Sesame-<digits>`
//     that is itself directly inside $TMPDIR. The digits are a process id: the helper's scratch folder is
//     `$TMPDIR/Sesame-<helper pid>` (tester-plan-1-t34-1 finding 1), and the app's own pid is not the helper's, so the
//     tests accept the app's own pid and another number. After a load the file is deleted. The image is read from
//     the bytes (NSImage(data:)), so it still draws after the file is gone. A path that only starts like the folder
//     (a sibling `Sesame-<pid>x`, `..` going out, a symlink pointing out) is refused, and a refused file is left
//     alone (never deleted). Bytes that are not a PNG (text, a JPEG named .png, the 8 signature bytes alone, an
//     empty file) are refused. Whether a refused non-PNG file inside the scratch folder is deleted is not pinned.
//  2. Opener (pure decisions; nothing here opens an app).
//       enum OpenAction: Equatable { case defaultApp(URL); case preview(URL, page: Int?);
//                                    case quickTime(URL, seconds: Int?) }
//       Opener.action(kind: String, path: String, spot: Int?) -> OpenAction
//     `kind` is the engine's kind word: photo, pdf, doc, audio, video. `spot` is the page (pdf) or the whole
//     seconds (audio, video); nil when there is none; it is ignored for photo, doc and any other kind (code
//     included). The URL inside is `URL(fileURLWithPath: path)`.
//       Opener.opensInText(kind: String, defaultAppName: String) -> String
//     "Opens in <app>": one app per kind for pdf (Preview), audio and video (QuickTime Player); the
//     default app's name (`urlForApplication(toOpen:)`, passed in) for photo, doc and any other kind.
//       Opener.copyFileURL(selectedTextLength: Int, path: String?, to: NSPasteboard) -> Bool
//     Command+C: when the box has no selected text (length 0) and a row is selected (path non-nil), the file URL goes
//     on the pasteboard (replacing its contents) and the result is true (the key is used up). Otherwise nothing is
//     written and the result is false (the box's own copy, or nothing, happens). It does not look at the disk.
//       Opener.isGone(path: String) -> Bool
//     true when no file is at the path; the caller asks it before Enter, Command+Enter and Command+C.
//  3. Pane.
//       Pane.statusText(_ status: PreviewStatus) -> String?
//     the line the pane shows for a preview reply's status: nil for ok, "changed since indexed" for changed, "That
//     file is no longer there" for gone.
//  4. ResultList (the gone-file state, a pure value; the real list wraps it).
//       struct RowSelection: Equatable {
//           init(paths: [String])              // the first row is selected, none when empty
//           var paths: [String] { get }
//           var selectedPath: String? { get }  // nil when empty
//           mutating func select(path: String) // an unknown path changes nothing
//           mutating func dropGone(_ path: String)
//       }
//     dropGone removes that row. When the removed row was the selected one the next row becomes selected (the row
//     that sat below it), or the new last row when it was the last (guess: the spec says only "selects the next
//     one"); when another row was removed the selection stays on the same file; an unknown path changes nothing.
//
// NOT covered here (needs the running app, the person's HARD RULE; the kit checks S1.5, S1.7 to S1.11, S1.14, S1.15
// are not shown red): the drawn pane, Enter really opening an app, Command+Enter really revealing in Finder, the
// helper's `preview` reply reaching the pane (HelperClient has one delegate; the app's `HelperEmbedder` sets itself as
// it today, so t37 has to share it), and the 1 s wait for the reply at Enter (design section 5).

// MARK: helpers

private let spTmp: String = {
    var tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    while tmp.count > 1 && tmp.hasSuffix("/") { tmp.removeLast() }
    return tmp
}()

private let spOwnPid = Int(ProcessInfo.processInfo.processIdentifier)
// A pid that is not this process's: stands for the helper's.
private let spHelperPid = spOwnPid + 1000

// A real PNG that the test paints itself: solid red, width x height pixels.
private func spPNG(width: Int = 7, height: Int = 5) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<width { for y in 0..<height { rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
    return rep.representation(using: .png, properties: [:])!
}

// A real JPEG (same picture), to be named .png.
private func spJPEG() -> Data {
    let rep = NSBitmapImageRep(data: spPNG())!
    return rep.representation(using: .jpeg, properties: [:])!
}

// The scratch folders and files a test makes, all removed at the end. A folder the test did not make is only cleaned
// of the files the test wrote, and removed if that leaves it empty.
private final class SPSandbox {
    private var files: [URL] = []
    private var folders: [(url: URL, made: Bool)] = []

    func folder(_ name: String) -> URL {
        let url = URL(fileURLWithPath: spTmp).appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !existed { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        folders.append((url, !existed))
        return url
    }

    func uniqueFolder(prefix: String) -> URL { folder("\(prefix)-\(UUID().uuidString)") }

    @discardableResult
    func write(_ data: Data, in folder: URL, name: String = "\(UUID().uuidString).png") -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: data)
        files.append(url)
        return url
    }

    func symlink(_ name: String, in folder: URL, to target: URL) -> URL {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        files.append(url)
        return url
    }

    func cleanup() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        for (url, made) in folders.reversed() {
            let left = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if made || left.isEmpty { try? FileManager.default.removeItem(at: url) }
        }
    }
}

// The pixel at (x, y) of an image, read through its TIFF data (this fails, empty, for an image that still points at a
// file that is gone).
private func spPixel(_ image: NSImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double, width: Int, height: Int)? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
    return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
            rep.pixelsWide, rep.pixelsHigh)
}

private func spLoad(_ url: URL) -> NSImage? { ScratchPNG.load(path: url.path) }

// MARK: ScratchPNG

@Suite("ScratchPNGTests")
struct ScratchPNGTests {

    @MainActor
    @Test func aPNGDirectlyUnderTmpdirSesamePidLoadsWithItsPixelsAndTheFileIsDeleted() {
        let box = SPSandbox(); defer { box.cleanup() }
        let folder = box.folder("Sesame-\(spOwnPid)")
        let file = box.write(spPNG(width: 7, height: 5), in: folder)

        let image = spLoad(file)

        #expect(image != nil, "a PNG under \(folder.path) was refused")
        #expect(!FileManager.default.fileExists(atPath: file.path), "the PNG was not deleted after it was loaded")
        guard let image else { return }
        // Read after the file is gone: the picture must not depend on the file. (That it is made with NSImage(data:)
        // is a source fact; the kit's static check and review hold it, a behaviour test cannot tell the two apart.)
        let pixel = spPixel(image, x: 3, y: 2)
        #expect(pixel != nil, "the loaded image cannot be read once its file is gone")
        if let pixel {
            #expect(pixel.width == 7 && pixel.height == 5, "pixels \(pixel.width) x \(pixel.height), wanted 7 x 5")
            #expect(pixel.r > 0.85 && pixel.g < 0.15 && pixel.b < 0.15,
                    "pixel (\(pixel.r), \(pixel.g), \(pixel.b)), wanted the red the test painted")
        }
    }

    @MainActor
    @Test func aPNGInTheHelpersScratchFolderLoadsToo() {
        // the helper's pid is not the app's pid, and the pane shows the helper's PNG
        let box = SPSandbox(); defer { box.cleanup() }
        let folder = box.folder("Sesame-\(spHelperPid)")
        let file = box.write(spPNG(width: 11, height: 3), in: folder)

        let image = spLoad(file)

        #expect(image != nil, "a PNG under \(folder.path) was refused")
        #expect(!FileManager.default.fileExists(atPath: file.path), "the PNG was not deleted after it was loaded")
        if let image, let pixel = spPixel(image, x: 0, y: 0) {
            #expect(pixel.width == 11 && pixel.height == 3, "pixels \(pixel.width) x \(pixel.height), wanted 11 x 3")
        }
    }

    @MainActor
    @Test func loadingTheSamePathAgainGivesNothingBecauseTheFileIsGone() {
        let box = SPSandbox(); defer { box.cleanup() }
        let folder = box.folder("Sesame-\(spOwnPid)")
        let file = box.write(spPNG(), in: folder)

        #expect(spLoad(file) != nil)
        #expect(spLoad(file) == nil, "a deleted file loaded again")
    }

    @MainActor
    @Test func aMissingFileUnderTheRightFolderIsRefusedWithoutFailing() {
        let box = SPSandbox(); defer { box.cleanup() }
        let folder = box.folder("Sesame-\(spOwnPid)")
        let missing = folder.appendingPathComponent("\(UUID().uuidString).png")

        #expect(spLoad(missing) == nil)
    }

    @MainActor
    @Test func anEmptyPathIsRefused() {
        #expect(ScratchPNG.load(path: "") == nil)
    }

    // MARK: a PNG anywhere else is refused, and left where it is

    @MainActor
    @Test func aPNGInAFolderNotNamedSesamePidIsRefusedAndKept() {
        let box = SPSandbox(); defer { box.cleanup() }
        let data = spPNG()
        let elsewhere = box.uniqueFolder(prefix: "elsewhere")
        let inElsewhere = box.write(data, in: elsewhere)

        #expect(spLoad(inElsewhere) == nil, "a PNG in \(elsewhere.path) was loaded")
        #expect(FileManager.default.contents(atPath: inElsewhere.path) == data,
                "a refused PNG was deleted or changed")
    }

    @MainActor
    @Test func aPNGDirectlyInTmpdirIsRefusedAndKept() {
        let box = SPSandbox(); defer { box.cleanup() }
        let data = spPNG()
        let direct = box.write(data, in: URL(fileURLWithPath: spTmp, isDirectory: true))

        #expect(spLoad(direct) == nil, "a PNG directly in $TMPDIR was loaded")
        #expect(FileManager.default.contents(atPath: direct.path) == data, "a refused PNG was deleted or changed")
    }

    @MainActor
    @Test func aFolderThatOnlyStartsWithSesamePidIsRefusedAndKept() {
        let box = SPSandbox(); defer { box.cleanup() }
        let data = spPNG()
        // string-prefix look-alikes of `Sesame-<pid>`, and names where the part after the dash is not a number
        for name in ["Sesame-\(spOwnPid)x", "Sesame-\(spOwnPid)-old", "Sesame-abc", "Sesame-", "Sesame", "sesame-\(spOwnPid)"] {
            let folder = box.folder(name)
            let file = box.write(data, in: folder)
            #expect(spLoad(file) == nil, "a PNG in a folder named \(name) was loaded")
            #expect(FileManager.default.contents(atPath: file.path) == data, "the refused PNG in \(name) was deleted")
        }
    }

    @MainActor
    @Test func aPathThatLeavesTheScratchFolderWithDotDotIsRefusedAndKept() {
        let box = SPSandbox(); defer { box.cleanup() }
        let data = spPNG()
        let scratch = box.folder("Sesame-\(spOwnPid)")
        let elsewhere = box.uniqueFolder(prefix: "elsewhere")
        let target = box.write(data, in: elsewhere, name: "target.png")
        let sneaky = scratch.path + "/../" + elsewhere.lastPathComponent + "/target.png"

        #expect(ScratchPNG.load(path: sneaky) == nil, "a path through .. was loaded: \(sneaky)")
        #expect(FileManager.default.contents(atPath: target.path) == data, "the file outside was deleted")
    }

    @MainActor
    @Test func aSymlinkInTheScratchFolderPointingOutIsRefusedAndTheTargetKept() {
        let box = SPSandbox(); defer { box.cleanup() }
        let data = spPNG()
        let scratch = box.folder("Sesame-\(spOwnPid)")
        let elsewhere = box.uniqueFolder(prefix: "elsewhere")
        let target = box.write(data, in: elsewhere, name: "target.png")
        let link = box.symlink("\(UUID().uuidString).png", in: scratch, to: target)

        #expect(spLoad(link) == nil, "a symlink out of the scratch folder was followed")
        #expect(FileManager.default.contents(atPath: target.path) == data, "the file the link points at was deleted")
    }

    // MARK: bytes that are not a PNG

    @MainActor
    @Test func bytesThatAreNotAPNGAreRefused() {
        let box = SPSandbox(); defer { box.cleanup() }
        let folder = box.folder("Sesame-\(spOwnPid)")
        let signatureOnly = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let cases: [(String, Data)] = [
            ("plain text", Data("this is not a picture".utf8)),
            ("a JPEG named .png", spJPEG()),
            ("only the 8 PNG signature bytes", signatureOnly),
            ("an empty file", Data()),
        ]
        for (what, data) in cases {
            let file = box.write(data, in: folder)
            #expect(spLoad(file) == nil, "\(what) under the scratch folder was loaded")
        }
    }
}

// MARK: Opener

private func spPathURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

@Suite("OpenerTests")
struct OpenerTests {

    // MARK: "Opens in <app>"

    @MainActor
    @Test func opensInTextNamesTheDefaultAppForPhotosDocumentsAndOtherKinds() {
        #expect(Opener.opensInText(kind: "photo", defaultAppName: "Preview") == "Opens in Preview")
        #expect(Opener.opensInText(kind: "photo", defaultAppName: "Pixelmator Pro") == "Opens in Pixelmator Pro")
        #expect(Opener.opensInText(kind: "doc", defaultAppName: "TextEdit") == "Opens in TextEdit")
        #expect(Opener.opensInText(kind: "doc", defaultAppName: "Pages") == "Opens in Pages")
        // an unknown kind is opened the plain way
        #expect(Opener.opensInText(kind: "mystery", defaultAppName: "Finder") == "Opens in Finder")
    }

    @MainActor
    @Test func opensInTextIsOneAppForPDFsAndMediaWhateverTheDefaultIs() {
        #expect(Opener.opensInText(kind: "pdf", defaultAppName: "Adobe Acrobat") == "Opens in Preview")
        #expect(Opener.opensInText(kind: "pdf", defaultAppName: "Preview") == "Opens in Preview")
        #expect(Opener.opensInText(kind: "audio", defaultAppName: "Music") == "Opens in QuickTime Player")
        #expect(Opener.opensInText(kind: "video", defaultAppName: "VLC") == "Opens in QuickTime Player")
    }

    // MARK: what Enter opens

    @MainActor
    @Test func aPhotoOrDocumentOpensInTheDefaultAppWithNoSpot() {
        let photo = "/Users/test/Pictures/beach dog.jpg"
        #expect(Opener.action(kind: "photo", path: photo, spot: nil) == .defaultApp(spPathURL(photo)))
        #expect(Opener.action(kind: "photo", path: photo, spot: 4) == .defaultApp(spPathURL(photo)),
                "a spot changed how a photo opens")
        let doc = "/Users/test/Documents/lease.docx"
        #expect(Opener.action(kind: "doc", path: doc, spot: nil) == .defaultApp(spPathURL(doc)))
        #expect(Opener.action(kind: "doc", path: doc, spot: 2) == .defaultApp(spPathURL(doc)))
        #expect(Opener.action(kind: "mystery", path: doc, spot: nil) == .defaultApp(spPathURL(doc)))
    }

    @MainActor
    @Test func aPDFOpensInPreviewAtThePage() {
        let pdf = "/Users/test/Documents/Q3 board deck.pdf"
        #expect(Opener.action(kind: "pdf", path: pdf, spot: 12) == .preview(spPathURL(pdf), page: 12))
        #expect(Opener.action(kind: "pdf", path: pdf, spot: nil) == .preview(spPathURL(pdf), page: nil))
    }

    @MainActor
    @Test func audioAndVideoOpenInQuickTimePlayerAtTheSecond() {
        let audio = "/Users/test/Music/interview.m4a"
        let video = "/Users/test/Movies/trip.mov"
        #expect(Opener.action(kind: "audio", path: audio, spot: 95) == .quickTime(spPathURL(audio), seconds: 95))
        #expect(Opener.action(kind: "video", path: video, spot: 0) == .quickTime(spPathURL(video), seconds: 0))
        #expect(Opener.action(kind: "video", path: video, spot: nil) == .quickTime(spPathURL(video), seconds: nil))
    }

    // MARK: Command+C

    @MainActor
    private func spPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sesame.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        return pasteboard
    }

    @MainActor
    private func spFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @MainActor
    @Test func commandCPutsTheFileURLOnThePasteboardWhenNoTextIsSelected() throws {
        let box = SPSandbox(); defer { box.cleanup() }
        let file = box.write(spPNG(), in: box.uniqueFolder(prefix: "copy"), name: "beach dog.png")
        let pasteboard = spPasteboard(); defer { pasteboard.releaseGlobally() }

        let used = Opener.copyFileURL(selectedTextLength: 0, path: file.path, to: pasteboard)

        #expect(used, "the key was not used up")
        let urls = spFileURLs(pasteboard)
        #expect(urls.map { $0.standardizedFileURL.path } == [file.standardizedFileURL.path],
                "the pasteboard holds \(urls) for \(file.path)")
    }

    @MainActor
    @Test func commandCLeavesThePasteboardAloneWhenTextInTheBoxIsSelected() {
        let box = SPSandbox(); defer { box.cleanup() }
        let file = box.write(spPNG(), in: box.uniqueFolder(prefix: "copy"))
        let pasteboard = spPasteboard(); defer { pasteboard.releaseGlobally() }

        let used = Opener.copyFileURL(selectedTextLength: 3, path: file.path, to: pasteboard)

        #expect(!used, "the file copy took the key while text was selected")
        #expect(pasteboard.string(forType: .string) == "keep me", "the pasteboard was changed")
        #expect(spFileURLs(pasteboard).isEmpty, "a file URL was written while text was selected")
    }

    @MainActor
    @Test func commandCDoesNothingWithNoResults() {
        let pasteboard = spPasteboard(); defer { pasteboard.releaseGlobally() }

        #expect(!Opener.copyFileURL(selectedTextLength: 0, path: nil, to: pasteboard))
        #expect(!Opener.copyFileURL(selectedTextLength: 2, path: nil, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "keep me", "the pasteboard was changed")
        #expect(spFileURLs(pasteboard).isEmpty)
    }

    // MARK: a gone file

    @MainActor
    @Test func aFileIsGoneWhenNothingIsAtItsPath() {
        let box = SPSandbox(); defer { box.cleanup() }
        let folder = box.uniqueFolder(prefix: "gone")
        let file = box.write(Data("x".utf8), in: folder, name: "there.txt")

        #expect(!Opener.isGone(path: file.path))
        try? FileManager.default.removeItem(at: file)
        #expect(Opener.isGone(path: file.path))
        #expect(Opener.isGone(path: folder.appendingPathComponent("never-was.txt").path))
    }
}

// MARK: Pane

@Suite("PaneStatusTextTests")
struct PaneStatusTextTests {

    @MainActor
    @Test func eachPreviewStatusHasItsLine() {
        #expect(Pane.statusText(.ok) == nil, "an ok preview carries a note")
        #expect(Pane.statusText(.changed) == "changed since indexed")
        #expect(Pane.statusText(.gone) == "That file is no longer there")
    }
}

// MARK: ResultList: dropping a gone file

@Suite("GoneFileRowsTests")
struct GoneFileRowsTests {

    private let a = "/Users/test/Pictures/a.jpg"
    private let b = "/Users/test/Pictures/b.jpg"
    private let c = "/Users/test/Pictures/c.jpg"
    private let d = "/Users/test/Pictures/d.jpg"

    @MainActor
    @Test func theFirstRowStartsSelectedAndAnEmptyListSelectsNothing() {
        let rows = RowSelection(paths: [a, b, c])
        #expect(rows.paths == [a, b, c])
        #expect(rows.selectedPath == a)
        #expect(RowSelection(paths: []).selectedPath == nil)
    }

    @MainActor
    @Test func droppingTheSelectedMiddleRowSelectsTheNextOne() {
        var rows = RowSelection(paths: [a, b, c, d])
        rows.select(path: b)
        rows.dropGone(b)
        #expect(rows.paths == [a, c, d])
        #expect(rows.selectedPath == c, "selected \(String(describing: rows.selectedPath)), wanted the next row")
    }

    @MainActor
    @Test func droppingTheSelectedFirstRowSelectsTheOldSecondRow() {
        var rows = RowSelection(paths: [a, b, c])
        rows.dropGone(a)
        #expect(rows.paths == [b, c])
        #expect(rows.selectedPath == b)
    }

    @MainActor
    @Test func droppingTheSelectedLastRowSelectsTheNewLastRow() {
        var rows = RowSelection(paths: [a, b, c])
        rows.select(path: c)
        rows.dropGone(c)
        #expect(rows.paths == [a, b])
        #expect(rows.selectedPath == b, "selected \(String(describing: rows.selectedPath)), wanted the new last row (guess)")
    }

    @MainActor
    @Test func droppingTheOnlyRowLeavesAnEmptyListWithNothingSelected() {
        var rows = RowSelection(paths: [a])
        rows.dropGone(a)
        #expect(rows.paths.isEmpty)
        #expect(rows.selectedPath == nil)
    }

    @MainActor
    @Test func droppingAnotherRowKeepsTheSelectionOnTheSameFile() {
        var above = RowSelection(paths: [a, b, c])
        above.select(path: c)
        above.dropGone(a)
        #expect(above.paths == [b, c])
        #expect(above.selectedPath == c)

        var below = RowSelection(paths: [a, b, c])
        below.select(path: a)
        below.dropGone(c)
        #expect(below.paths == [a, b])
        #expect(below.selectedPath == a)
    }

    @MainActor
    @Test func droppingAPathThatIsNotInTheListChangesNothing() {
        var rows = RowSelection(paths: [a, b])
        rows.select(path: b)
        rows.dropGone(c)
        #expect(rows.paths == [a, b])
        #expect(rows.selectedPath == b)
    }

    @MainActor
    @Test func droppingRowsOneByOneWalksDownTheListToEmpty() {
        // Enter on a gone file again and again: each press drops the selected row and lands on the next one
        var rows = RowSelection(paths: [a, b, c])
        var seen: [String?] = [rows.selectedPath]
        while let selected = rows.selectedPath {
            rows.dropGone(selected)
            seen.append(rows.selectedPath)
        }
        #expect(seen == [a, b, c, nil], "selection walked \(seen)")
        #expect(rows.paths.isEmpty)
    }
}
