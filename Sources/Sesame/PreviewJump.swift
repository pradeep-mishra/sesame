import AppKit
import Foundation

/// Builds the Apple Event that opens a PDF in Preview with search text.
/// It only builds the event; it sends nothing.
enum PreviewJump {
    static let previewBundleID = "com.apple.Preview"
    static let maxSearchLength = 500

    /// `aevt`/`odoc` (kAEOpenDocuments) addressed to Preview, direct object the file URL,
    /// `keyAESearchText` ('stxt') the text trimmed of spaces and cut at 500 characters.
    /// The parameter is left out for nil, empty and only-spaces text.
    static func openEvent(file: URL, searchText: String?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: previewBundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(fileURL: file), forKeyword: AEKeyword(keyDirectObject))
        if let text = searchText {
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if !trimmed.isEmpty {
                event.setParam(
                    NSAppleEventDescriptor(string: String(trimmed.prefix(maxSearchLength))),
                    forKeyword: AEKeyword(keyAESearchText))
            }
        }
        return event
    }
}
