import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import SesameEngine

// plan-4-t7, tester step of the Vision fix round. Written from the brief only; no product source is read.
//
// Names: `RecognitionRetry.run(_ attempt: () throws -> String) throws -> String` and the error type `RecognitionFailed` come from
// the brief (they do not exist yet, so this file is red for that reason). `PhotoReader.recognizeText(in:orientation:)` is the
// existing name; it is called with `try` so it compiles whether or not it throws.
//
// Every expected value is written by hand: the number of calls, the words drawn, the fake paths.

/// An error whose text holds a path, as a Vision or file error could.
private struct FakeVisionError: Error, CustomStringConvertible {
    let path: String
    var description: String { "request failed for \(path)" }
}

private let firstPath = "/Users/someone/Pictures/secret-holiday-photo.jpg"
private let secondPath = "/Volumes/Backup/private-folder/receipt-scan.pdf"

private func visionCannotReadWhite() -> CGImage? {
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    return context.makeImage()
}

/// `word` in large bold black letters on white.
private func pictureOfWord(_ word: String) -> CGImage? {
    let width = 800, height = 300
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 150, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: 40, y: 100)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attributes)), context)
    return context.makeImage()
}

@Suite("RecognitionRetryTests")
struct RecognitionRetryTests {
    @Test("an attempt that does not throw is called once and its result is returned")
    func successIsCalledOnce() throws {
        var calls = 0
        let result = try RecognitionRetry.run { calls += 1; return "saddle walnut" }
        #expect(result == "saddle walnut", "expected the attempt's own result, got \"\(result)\"")
        #expect(calls == 1, "a first success must not be repeated: the attempt ran \(calls) times")
    }

    @Test("an empty result is a picture with no text: returned as is and never retried")
    func emptyResultIsNotRetried() throws {
        var calls = 0
        let result = try RecognitionRetry.run { calls += 1; return "" }
        #expect(result == "", "expected an empty read, got \"\(result)\"")
        #expect(calls == 1, "an empty result must not trigger a retry: the attempt ran \(calls) times")
    }

    @Test("a first throw is retried exactly once and the second result is returned")
    func firstThrowThenSuccess() throws {
        var calls = 0
        let result = try RecognitionRetry.run {
            calls += 1
            if calls == 1 { throw FakeVisionError(path: firstPath) }
            return "cobbler"
        }
        #expect(result == "cobbler", "expected the second result, got \"\(result)\"")
        #expect(calls == 2, "expected exactly two calls, got \(calls)")
    }

    @Test("a first throw then an empty result returns the empty string: a picture with no text, not a failure")
    func firstThrowThenEmpty() throws {
        var calls = 0
        let result = try RecognitionRetry.run {
            calls += 1
            if calls == 1 { throw FakeVisionError(path: firstPath) }
            return ""
        }
        #expect(result == "", "expected an empty read, got \"\(result)\"")
        #expect(calls == 2, "expected exactly two calls, got \(calls)")
    }

    @Test("two throws end in RecognitionFailed after exactly two calls, never more")
    func twoThrowsFail() {
        var calls = 0
        var caught: Error?
        do {
            _ = try RecognitionRetry.run {
                calls += 1
                throw FakeVisionError(path: firstPath)
            }
        } catch {
            caught = error
        }
        #expect(caught is RecognitionFailed, "expected RecognitionFailed, got \(String(describing: caught))")
        #expect(calls == 2, "expected exactly two calls, got \(calls)")
    }

    @Test("the RecognitionFailed text holds no path and no file name, from either attempt's error")
    func failureTextHoldsNoPath() {
        var calls = 0
        var caught: Error?
        do {
            _ = try RecognitionRetry.run {
                calls += 1
                throw FakeVisionError(path: calls == 1 ? firstPath : secondPath)
            }
        } catch {
            caught = error
        }
        guard let caught else {
            Issue.record("two throwing attempts did not throw")
            return
        }
        #expect(caught is RecognitionFailed, "expected RecognitionFailed, got \(caught)")
        let texts = ["\(caught)", String(describing: caught), String(reflecting: caught), caught.localizedDescription]
        let leaks = ["/Users", "someone", "secret-holiday-photo", ".jpg", "/Volumes", "private-folder", "receipt-scan", ".pdf",
                     firstPath, secondPath]
        for text in texts {
            for leak in leaks {
                #expect(!text.contains(leak), "the error text \"\(text)\" holds \"\(leak)\"")
            }
        }
    }

    // MARK: the real Vision control

    @Test("real Vision on a plain white 100 x 100 picture gives an empty string and does not throw")
    func whitePictureReadsEmpty() throws {
        let image = try #require(visionCannotReadWhite())
        let read = try PhotoReader.recognizeText(in: image, orientation: .up)
        #expect(read == "", "a plain white picture read \"\(read)\"")
    }

    @Test("real Vision on a picture of large black text gives text that holds the drawn word")
    func drawnWordIsRead() throws {
        let image = try #require(pictureOfWord("WALNUT"))
        let read = try PhotoReader.recognizeText(in: image, orientation: .up)
        #expect(read.lowercased().contains("walnut"), "text recognition read \"\(read)\", expected the word walnut")
    }
}
