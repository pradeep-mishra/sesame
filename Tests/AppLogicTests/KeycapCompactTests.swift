import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let kcControl = "\u{2303}"
private let kcOption = "\u{2325}"
private let kcShift = "\u{21E7}"
private let kcCommand = "\u{2318}"
private let kcLooks: [DTLook] = [.light, .dark, .light]
private let kcSymbols = ["Control": kcControl, "Option": kcOption, "Shift": kcShift, "Command": kcCommand]

@MainActor
private func kcBuild(_ text: String, _ look: DTLook = .light, style: KeycapStyle = .compact) -> (host: NSView, row: KeycapRow) {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
    host.appearance = dtAppearance(look)
    let row = KeycapRow(style: style)
    row.text = text
    row.frame = NSRect(origin: NSPoint(x: 10, y: 10), size: row.intrinsicContentSize)
    host.addSubview(row)
    host.layoutSubtreeIfNeeded()
    return (host, row)
}

@MainActor
private func kcKeys(_ row: NSView) -> [NSView] {
    let candidates = prViews(row).filter { view in
        view !== row && !(view is NSTextField) && view.layer?.cornerRadius == 6 && abs(view.frame.height - 26) <= 0.5
    }
    return candidates
        .filter { candidate in !sxAncestors(candidate).contains { ancestor in candidates.contains { $0 === ancestor } } }
        .sorted { plBox(row, $0).minX < plBox(row, $1).minX }
}

@MainActor
private func kcFace(_ row: NSView, _ key: NSView) -> NSTextField? {
    let box = plBox(row, key)
    return plTexts(row).first { field in
        let inner = plBox(row, field)
        return inner.midX >= box.minX && inner.midX <= box.maxX
            && (inner.top + inner.bottom) / 2 >= box.top && (inner.top + inner.bottom) / 2 <= box.bottom
    }
}

@MainActor
private func kcFaces(_ row: NSView) -> [String] {
    kcKeys(row).compactMap { kcFace(row, $0)?.stringValue }
}

private struct KCEdge {
    let width: CGFloat
    let height: CGFloat
    let bottomGap: CGFloat
    let fill: [CGFloat]?
}

@MainActor
private func kcEdges(_ key: NSView) -> [KCEdge] {
    guard let layer = key.layer else { return [] }
    let flipped = layer.isGeometryFlipped
    let whole = layer.bounds.height
    return (layer.sublayers ?? []).filter { abs($0.frame.height - 1) <= 0.05 }.map { sub in
        let top = flipped ? sub.frame.minY : whole - sub.frame.maxY
        return KCEdge(width: sub.frame.width, height: sub.frame.height, bottomGap: whole - (top + sub.frame.height), fill: dtRGBA(cgColor: sub.backgroundColor))
    }
}

private func kcLayerColours(_ layer: CALayer?) -> [CGColor] {
    guard let layer else { return [] }
    let own = [layer.backgroundColor, layer.borderColor].compactMap { $0 }
    return own + (layer.sublayers ?? []).flatMap { kcLayerColours($0) }
}

private func kcHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { kcHasGradient($0) }
}

private func kcWidth(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
}

private func kcKeyWidths(_ words: [String], padding: CGFloat) -> [CGFloat] {
    words.map { word in
        let symbol = kcSymbols[word]
        let width = symbol.map { kcWidth($0, 13, .regular) } ?? kcWidth(word, 12, .medium)
        return max(word == "Space" ? 52 : 26, width + 2 * padding)
    }
}

private func kcExpected(_ words: [String]) -> (widths: [CGFloat], padding: CGFloat, total: CGFloat) {
    let gaps = CGFloat(max(0, words.count - 1)) * 6
    let wide = kcKeyWidths(words, padding: 8)
    if wide.reduce(0, +) + gaps > 220 {
        let tight = kcKeyWidths(words, padding: 4)
        return (tight, 4, tight.reduce(0, +) + gaps)
    }
    return (wide, 8, wide.reduce(0, +) + gaps)
}

extension ModelDownloadTests {
    @Suite("KeycapCompactTests", .serialized)
    struct KeycapCompactTests {

        @MainActor
        @Test func aCompactRowOfControlOptionSpaceHoldsThreeKeysTwentySixHighSixApartTheSymbolsAtLeastTwentySixWideAndSpaceAtLeastFiftyTwo() {
            for look in kcLooks {
                let (_, row) = kcBuild("Control Option Space", look)
                let keys = kcKeys(row)
                #expect(keys.count == 3, "\(look): \(keys.count) keys")
                guard keys.count == 3 else { continue }
                let boxes = keys.map { plBox(row, $0) }
                for (index, box) in boxes.enumerated() {
                    #expect(abs(box.height - 26) <= 0.5, "\(look): key \(index) is \(box.height) tall")
                    #expect(abs(box.top) <= 0.5, "\(look): key \(index) starts \(box.top) below the row top")
                }
                #expect(boxes[0].width >= 26 - 0.5 && boxes[1].width >= 26 - 0.5, "\(look): symbol keys are \(boxes[0].width) and \(boxes[1].width) wide")
                #expect(boxes[2].width >= 52 - 0.5, "\(look): Space is \(boxes[2].width) wide")
                #expect(abs(boxes[1].minX - boxes[0].maxX - 6) <= 0.5 && abs(boxes[2].minX - boxes[1].maxX - 6) <= 0.5, "\(look): gaps \(boxes[1].minX - boxes[0].maxX) and \(boxes[2].minX - boxes[1].maxX)")
                #expect(abs(boxes[0].minX) <= 0.5, "\(look): the first key starts \(boxes[0].minX) from the row's left edge")
            }
        }

        @MainActor
        @Test func eachCompactKeyHasRadiusSixAHalfPointBorderAndAOnePointLowerEdgeInSeparatorColourAndACentredFaceInLabelColourAtThirteenRegularOrTwelveMedium() {
            for look in kcLooks {
                let (_, row) = kcBuild("Control Option Space", look)
                let keys = kcKeys(row)
                guard keys.count == 3 else {
                    Issue.record("\(look): \(keys.count) keys")
                    continue
                }
                let separator = dtRGBA(.separatorColor, look)
                for (index, key) in keys.enumerated() {
                    #expect(key.layer?.cornerRadius == 6, "\(look): key \(index) radius \(String(describing: key.layer?.cornerRadius))")
                    #expect(abs((key.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look): key \(index) border width \(String(describing: key.layer?.borderWidth))")
                    let border = dtRGBA(cgColor: key.layer?.borderColor)
                    #expect(border != nil && dtSame(border ?? [], separator), "\(look): key \(index) border \(String(describing: border))")
                    let edges = kcEdges(key)
                    #expect(edges.count == 1, "\(look): key \(index) has \(edges.count) lower edges")
                    if let edge = edges.first {
                        #expect(abs(edge.height - 1) <= 0.05, "\(look): key \(index) lower edge is \(edge.height) tall")
                        #expect(abs(edge.bottomGap) <= 1, "\(look): key \(index) lower edge is \(edge.bottomGap) above its bottom")
                        #expect(edge.width >= key.frame.width - 13 && edge.width <= key.frame.width + 0.5, "\(look): key \(index) lower edge is \(edge.width) wide in a \(key.frame.width) key")
                        #expect(edge.fill != nil && dtSame(edge.fill ?? [], separator), "\(look): key \(index) lower edge colour \(String(describing: edge.fill))")
                    }
                    guard let face = kcFace(row, key) else {
                        Issue.record("\(look): key \(index) has no face")
                        continue
                    }
                    let symbol = index < 2
                    #expect(sxFont(face.font, size: symbol ? 13 : 12, weight: symbol ? .regular : .medium), "\(look): key \(index) face font \(String(describing: face.font))")
                    #expect(sxColour(face.textColor, is: .labelColor), "\(look): key \(index) face colour")
                    let keyBox = plBox(row, key)
                    let faceBox = plBox(row, face)
                    #expect(abs(faceBox.midX - keyBox.midX) <= 1.5, "\(look): key \(index) face is \(faceBox.midX - keyBox.midX) off centre across")
                    #expect(abs((faceBox.top + faceBox.bottom) / 2 - (keyBox.top + keyBox.bottom) / 2) <= 2, "\(look): key \(index) face is off centre down")
                    #expect(faceBox.minX >= keyBox.minX - 0.5 && faceBox.maxX <= keyBox.maxX + 0.5, "\(look): key \(index) face spans \(faceBox.minX) to \(faceBox.maxX) in a key from \(keyBox.minX) to \(keyBox.maxX)")
                }
            }
        }

        @MainActor
        @Test func theCompactRowHoldsOnlyTheThreeFacesNoKeyNamesNoCaptionsAndItsIntrinsicSizeIsTwentySixHighAndTheKeysPlusTheGapsWide() {
            let (_, row) = kcBuild("Control Option Space")
            let texts = plTexts(row)
            #expect(texts.map(\.stringValue).sorted() == [kcControl, kcOption, "Space"].sorted(), "texts in the row: \(texts.map(\.stringValue))")
            #expect(!texts.contains { $0.stringValue.contains("Control") || $0.stringValue.contains("Option") }, "a key name is drawn: \(texts.map(\.stringValue))")
            #expect(!texts.contains { abs(($0.font?.pointSize ?? 0) - 11) < 0.01 }, "an 11 pt caption is drawn")
            let keys = kcKeys(row)
            let widths = keys.map { plBox(row, $0).width }
            let size = row.intrinsicContentSize
            #expect(abs(size.height - 26) <= 0.01, "the row's intrinsic height is \(size.height)")
            #expect(abs(size.width - (widths.reduce(0, +) + 12)) <= 0.5, "the row's intrinsic width is \(size.width), the keys are \(widths) with two gaps of 6")
            #expect(abs(row.frame.height - 26) <= 0.5, "the row is \(row.frame.height) tall")
            if let last = keys.last {
                #expect(abs(plBox(row, last).maxX - size.width) <= 0.5, "the last key ends at \(plBox(row, last).maxX), the row is \(size.width) wide")
                #expect(abs(plBox(row, last).bottom - 26) <= 0.5, "the last key ends \(plBox(row, last).bottom) below the row top")
            }
            #expect(!prViews(row).contains { $0 is NSScrollView }, "a scroll view in the row")
            #expect(!prViews(row).contains { $0 is NSVisualEffectView || kcHasGradient($0.layer) }, "an effect view or a gradient in the row")
        }

        @MainActor
        @Test func theCompactFillIsANeutralTranslucentGroupFillInBothLooksAndRepaintsWhenTheAppearanceChangesWithTheBorderEdgeAndFaces() {
            let (host, row) = kcBuild("Control Option Space", .light)
            for look in kcLooks {
                host.appearance = dtAppearance(look)
                host.layoutSubtreeIfNeeded()
                let keys = kcKeys(row)
                guard keys.count == 3 else {
                    Issue.record("\(look): \(keys.count) keys")
                    continue
                }
                let separator = dtRGBA(.separatorColor, look)
                for (index, key) in keys.enumerated() {
                    let fill = dtRGBA(cgColor: key.layer?.backgroundColor)
                    #expect(fill != nil, "\(look): key \(index) has no fill")
                    guard let fill else { continue }
                    #expect(abs(fill[0] - fill[1]) <= 0.02 && abs(fill[1] - fill[2]) <= 0.02, "\(look): key \(index) fill is not neutral: \(fill)")
                    #expect(fill[3] > 0 && fill[3] < 1, "\(look): key \(index) fill alpha \(fill[3])")
                    if look == .light {
                        #expect(fill[0] <= 0.2, "\(look): key \(index) fill is \(fill), a dark tint on a light look")
                    } else {
                        #expect(fill[0] >= 0.8, "\(look): key \(index) fill is \(fill), a light tint on a dark look")
                    }
                    let border = dtRGBA(cgColor: key.layer?.borderColor)
                    #expect(border != nil && dtSame(border ?? [], separator), "\(look): key \(index) border \(String(describing: border)) did not repaint")
                    for edge in kcEdges(key) {
                        #expect(edge.fill != nil && dtSame(edge.fill ?? [], separator), "\(look): key \(index) lower edge \(String(describing: edge.fill)) did not repaint")
                    }
                    #expect(kcFace(row, key).map { sxColour($0.textColor, is: .labelColor) } == true, "\(look): key \(index) face colour")
                    for cgColor in kcLayerColours(key.layer) {
                        guard let rgba = dtRGBA(cgColor: cgColor) else { continue }
                        let neutralFill = abs(rgba[0] - rgba[1]) <= 0.02 && abs(rgba[1] - rgba[2]) <= 0.02 && rgba[3] < 1
                        #expect(dtSame(rgba, separator) || neutralFill, "\(look): key \(index) draws \(rgba)")
                    }
                }
            }
        }

        @MainActor
        @Test func theKeysFollowTheSharedParsingFiveModifiersAndSpaceAnAnyLetterKeyAnFKeyAWordKeyAndTheLongestWordNamingThePaddingItEndsOn() {
            let cases: [(text: String, faces: [String])] = [
                ("Control Option Space", [kcControl, kcOption, "Space"]),
                ("Control Option Shift Command Space", [kcControl, kcOption, kcShift, kcCommand, "Space"]),
                ("Option Command K", [kcOption, kcCommand, "K"]),
                ("Control F12", [kcControl, "F12"]),
                ("Command F5", [kcCommand, "F5"]),
                ("Command Return", [kcCommand, "Return"]),
                ("Control Option Shift Command Bracketright", [kcControl, kcOption, kcShift, kcCommand, "Bracketright"]),
            ]
            for look in [DTLook.light, .dark] {
                for entry in cases {
                    let (_, row) = kcBuild(entry.text, look)
                    let keys = kcKeys(row)
                    let tag = "\(look) \"\(entry.text)\""
                    #expect(keys.count == entry.faces.count, "\(tag): \(keys.count) keys")
                    guard keys.count == entry.faces.count else { continue }
                    #expect(kcFaces(row) == entry.faces, "\(tag): faces \(kcFaces(row))")
                    let words = entry.text.split(separator: " ").map(String.init)
                    let expected = kcExpected(words)
                    let widths = keys.map { plBox(row, $0).width }
                    for (index, width) in widths.enumerated() {
                        #expect(width >= 26 - 0.5, "\(tag): key \(index) is \(width) wide, under 26")
                        #expect(abs(width - expected.widths[index]) <= 1.5, "\(tag): key \(index) is \(width) wide, wanted \(expected.widths[index]) with padding \(expected.padding)")
                    }
                    #expect(widths.last.map { $0 >= (words.last == "Space" ? 52 : 26) - 0.5 } == true, "\(tag): the last key is too narrow")
                    #expect(abs(row.intrinsicContentSize.width - expected.total) <= 3, "\(tag): the row is \(row.intrinsicContentSize.width) wide, wanted \(expected.total)")
                    for key in keys {
                        guard let face = kcFace(row, key) else { continue }
                        let line = ceil(face.font?.boundingRectForFont.height ?? 0)
                        let wanted = kcWidth(face.stringValue, face.font?.pointSize == 13 ? 13 : 12, face.font?.pointSize == 13 ? .regular : .medium)
                        #expect(plBox(row, face).width >= wanted - 0.5, "\(tag): \"\(face.stringValue)\" is cut to \(plBox(row, face).width), its text is \(wanted)")
                        #expect(plBox(row, face).height <= line + 2, "\(tag): \"\(face.stringValue)\" wraps: \(plBox(row, face).height) tall")
                        #expect(plBox(row, face).minX >= plBox(row, key).minX - 0.5 && plBox(row, face).maxX <= plBox(row, key).maxX + 0.5, "\(tag): \"\(face.stringValue)\" leaves its key")
                    }
                }
            }

            func widthOf(_ text: String, key index: Int) -> (width: CGFloat, row: CGFloat) {
                let (_, row) = kcBuild(text)
                let keys = kcKeys(row)
                return (keys.indices.contains(index) ? plBox(row, keys[index]).width : -1, row.intrinsicContentSize.width)
            }

            #expect(widthOf("Option Command K", key: 2).width >= 26 - 0.5, "the letter key K is under 26 wide")
            let fKey = widthOf("Control F12", key: 1).width
            #expect(abs(fKey - 37) <= 1.5, "F12 is \(fKey) wide, its word is 21 and the padding 8 each side")
            let word = widthOf("Command Return", key: 1).width
            #expect(abs(word - 55) <= 1.5, "Return is \(word) wide, its word is 39 and the padding 8 each side")

            let five = widthOf("Control Option Shift Command Space", key: 4)
            #expect(five.row <= 220.5, "five keys are \(five.row) wide")
            #expect(abs(five.width - 52) <= 1.5, "Space is \(five.width) wide with five keys")

            let longest = "Control Option Shift Command Bracketright"
            let total = widthOf(longest, key: 4)
            #expect(total.row <= 220.5, "the longest row is \(total.row) wide, over 220")
            #expect(abs(total.row - 208) <= 3, "the longest row is \(total.row) wide, wanted 208 (four 26 keys, Bracketright 80, four gaps of 6)")
            #expect(abs(total.width - 80) <= 1.5, "Bracketright is \(total.width) wide: its word is 72 and the padding it ends on is 4 each side")
            for index in 0..<4 {
                let modifier = widthOf(longest, key: index).width
                #expect(abs(modifier - 26) <= 0.5, "modifier key \(index) is \(modifier) wide, wanted its 26 minimum")
            }
        }

        @MainActor
        @Test func theCompactRowIsOneAccessibilityGroupLabelledWithTheFullTextWithNoChildrenAndNoKeyOrFaceAnElement() {
            for text in ["Control Option Space", "Option Command K", "Control Option Shift Command Space"] {
                let (_, row) = kcBuild(text)
                #expect(row.isAccessibilityElement(), "\(text): not an accessibility element")
                #expect(row.accessibilityRole() == .group, "\(text): role \(String(describing: row.accessibilityRole()))")
                #expect(row.accessibilityLabel() == text, "\(text): label \"\(row.accessibilityLabel() ?? "nil")\"")
                #expect((row.accessibilityChildren() ?? []).isEmpty, "\(text): the group has children")
                let inside = prViews(row).filter { $0 !== row && $0.isAccessibilityElement() }
                #expect(inside.isEmpty, "\(text): \(inside.count) keys or faces are accessibility elements")
            }
            let (_, row) = kcBuild("Control Option Space")
            row.text = "Option Command K"
            row.superview?.layoutSubtreeIfNeeded()
            #expect(row.accessibilityLabel() == "Option Command K", "the label after a new text is \"\(row.accessibilityLabel() ?? "nil")\"")
            #expect(kcFaces(row) == [kcOption, kcCommand, "K"], "the faces after a new text are \(kcFaces(row))")
        }

        @MainActor
        @Test func aRowWithNoStyleAndARowOfStyleSetupAreTodaysSetupRowFortyFourHighEightApartWithACaptionUnderEachKey() {
            let plain = KeycapRow()
            plain.text = "Control Option Space"
            let styled = KeycapRow(style: .setup)
            styled.text = "Control Option Space"
            for (name, row) in [("KeycapRow()", plain), ("KeycapRow(style: .setup)", styled)] {
                row.frame = NSRect(origin: .zero, size: row.intrinsicContentSize)
                row.layoutSubtreeIfNeeded()
                let keys = prViews(row).filter { $0 !== row && !($0 is NSTextField) && $0.layer?.cornerRadius == 8 && abs($0.frame.height - 44) <= 0.5 }
                    .sorted { plBox(row, $0).minX < plBox(row, $1).minX }
                #expect(keys.count == 3, "\(name): \(keys.count) keys 44 tall")
                guard keys.count == 3 else { continue }
                #expect(abs(plBox(row, keys[1]).minX - plBox(row, keys[0]).maxX - 8) <= 1, "\(name): the keys are not 8 apart")
                let captions = plTexts(row).filter { abs(($0.font?.pointSize ?? 0) - 11) < 0.01 }.map(\.stringValue)
                #expect(captions == ["Control", "Option", "Space"], "\(name): the captions are \(captions)")
                #expect(row.accessibilityLabel() == "Control Option Space", "\(name): label \"\(row.accessibilityLabel() ?? "nil")\"")
            }
        }
    }
}
