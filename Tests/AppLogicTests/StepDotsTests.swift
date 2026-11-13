import AppKit
import Foundation
import QuartzCore
import Testing
@testable import Sesame

private let sdSteps: [(step: SetupFlow.Step, title: String)] = [
    (.welcome, "Step 1 of 4: Welcome"),
    (.folders, "Step 2 of 4: Folders"),
    (.permissions, "Step 3 of 4: Permissions"),
    (.shortcut, "Step 4 of 4: Shortcut"),
]

@MainActor
private func sdHost(_ step: SetupFlow.Step, _ look: DTLook) -> (window: NSWindow, dots: StepDots) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.appearance = dtAppearance(look)
    let dots = StepDots(step: step)
    dots.frame = NSRect(x: 72, y: 26, width: 56, height: 8)
    dots.appearance = dtAppearance(look)
    window.contentView?.addSubview(dots)
    dots.layoutSubtreeIfNeeded()
    return (window, dots)
}

@MainActor
private func sdCircles(_ dots: StepDots) -> [NSView] {
    prViews(dots).dropFirst().filter { $0.layer?.cornerRadius == 4 }.sorted { $0.convert($0.bounds, to: dots).minX < $1.convert($1.bounds, to: dots).minX }
}

@MainActor
private func sdFill(_ dot: NSView) -> [CGFloat]? {
    dtRGBA(cgColor: dot.layer?.backgroundColor)
}

private func sdLayers(_ layer: CALayer?) -> [CALayer] {
    guard let layer else { return [] }
    return [layer] + (layer.sublayers ?? []).flatMap { sdLayers($0) }
}

@MainActor
private func sdCheckColours(_ dots: StepDots, current: Int, _ look: DTLook, _ where_: String) {
    let circles = sdCircles(dots)
    let accent = dtRGBA(NSColor.controlAccentColor, look)
    let idle = dtRGBA(NSColor.tertiaryLabelColor, look)
    #expect(!dtSame(accent, idle), "\(where_): the accent and the idle colour are the same in the test")
    #expect(circles.count == 4, "\(where_): \(circles.count) dots")
    for (index, dot) in circles.enumerated() where circles.count == 4 {
        let fill = sdFill(dot) ?? []
        let expected = index == current ? accent : idle
        let name = index == current ? "controlAccentColor" : "tertiaryLabelColor"
        #expect(dtSame(fill, expected), "\(where_): dot \(index + 1) fills \(fill), expected \(name) \(expected)")
    }
}

@MainActor
@Suite("StepDotsTests", .serialized)
struct StepDotsTests {

    @Test func thereAreFourDotsEachAnEightPointCircleOfCornerRadiusFourEightPointsApartInOneRow() {
        for (step, title) in sdSteps {
            let host = sdHost(step, .light)
            let circles = sdCircles(host.dots)
            #expect(circles.count == 4, "\(title): \(circles.count) dots")
            guard circles.count == 4 else { continue }
            let frames = circles.map { $0.convert($0.bounds, to: host.dots) }
            for (index, frame) in frames.enumerated() {
                #expect(abs(frame.width - 8) < 0.01 && abs(frame.height - 8) < 0.01, "\(title): dot \(index + 1) is \(frame.width) x \(frame.height)")
                #expect(circles[index].layer?.cornerRadius == 4, "\(title): dot \(index + 1) corner radius")
                #expect(abs(frame.minY - frames[0].minY) < 0.01, "\(title): dot \(index + 1) is not in the row of dot 1")
            }
            for index in 1..<4 {
                #expect(abs(frames[index].minX - frames[index - 1].maxX - 8) < 0.01, "\(title): gap before dot \(index + 1) is \(frames[index].minX - frames[index - 1].maxX)")
            }
            let span = frames[3].maxX - frames[0].minX
            #expect(abs(span - 56) < 0.01, "\(title): the row is \(span) wide")
            #expect(abs((frames[0].minX + frames[3].maxX) / 2 - host.dots.bounds.midX) < 0.5, "\(title): the row is not centred in the view")
            #expect(abs((frames[0].minY + frames[0].maxY) / 2 - host.dots.bounds.midY) < 0.5, "\(title): the row is not centred up and down in the view")
        }
    }

    @Test func theDotOfTheCurrentStepIsTheAccentColourAndTheOtherThreeAreTheTertiaryLabelColourInLightAndDark() {
        for look in DTLook.allCases {
            for (index, entry) in sdSteps.enumerated() {
                let host = sdHost(entry.step, look)
                sdCheckColours(host.dots, current: index, look, "\(look) / \(entry.title)")
            }
        }
    }

    @Test func settingTheStepRecoloursTheSameDotsForEveryStepInLightAndDark() {
        for look in DTLook.allCases {
            let host = sdHost(.welcome, look)
            let before = sdCircles(host.dots)
            for index in Array(sdSteps.indices.reversed()) + Array(sdSteps.indices) {
                let entry = sdSteps[index]
                host.dots.step = entry.step
                host.dots.layoutSubtreeIfNeeded()
                sdCheckColours(host.dots, current: index, look, "\(look) / set to \(entry.title)")
                let after = sdCircles(host.dots)
                #expect(after.count == before.count && zip(before, after).allSatisfy { $0 === $1 }, "\(look) / set to \(entry.title): the dots were rebuilt")
            }
        }
    }

    @Test func theColoursFollowTheAppearanceWhenItChangesWithoutChangingTheStep() {
        let host = sdHost(.folders, .light)
        sdCheckColours(host.dots, current: 1, .light, "light first")
        host.dots.appearance = dtAppearance(.dark)
        host.dots.layoutSubtreeIfNeeded()
        sdCheckColours(host.dots, current: 1, .dark, "then dark")
        host.dots.appearance = dtAppearance(.light)
        host.dots.layoutSubtreeIfNeeded()
        sdCheckColours(host.dots, current: 1, .light, "then light again")
    }

    @Test func theViewIsExactlyOneAccessibilityGroupTitledStepNOfFourWithNoDotsAsElements() {
        for (step, title) in sdSteps {
            let host = sdHost(step, .light)
            #expect(host.dots.isAccessibilityElement(), "\(title): the view is not an accessibility element")
            #expect(host.dots.accessibilityRole() == .group, "\(title): role \(String(describing: host.dots.accessibilityRole()))")
            #expect(host.dots.accessibilityTitle() == title, "\(title): title \(String(describing: host.dots.accessibilityTitle()))")
            let below = prViews(host.dots).dropFirst()
            #expect(!below.isEmpty, "\(title): no subviews")
            for view in below {
                #expect(!view.isAccessibilityElement(), "\(title): a \(type(of: view)) under the view is an accessibility element")
            }
            #expect((host.dots.accessibilityChildren() ?? []).isEmpty, "\(title): the group has accessibility children")
        }
    }

    @Test func theTitleChangesWithTheStepOnTheSameViewWithoutRebuildingIt() {
        let host = sdHost(.welcome, .light)
        let before = prViews(host.dots)
        #expect(host.dots.accessibilityTitle() == "Step 1 of 4: Welcome")
        for entry in sdSteps.dropFirst() + sdSteps.dropLast().reversed() {
            host.dots.step = entry.step
            #expect(host.dots.accessibilityTitle() == entry.title, "after \(entry.title): title \(String(describing: host.dots.accessibilityTitle()))")
            #expect(host.dots.isAccessibilityElement() && host.dots.accessibilityRole() == .group, "after \(entry.title): not one group element")
            let after = prViews(host.dots)
            #expect(after.count == before.count && zip(before, after).allSatisfy { $0 === $1 }, "after \(entry.title): the views were rebuilt")
        }
    }

    @Test func noLayerOfTheViewIsAGradient() {
        for look in DTLook.allCases {
            for (step, title) in sdSteps {
                let host = sdHost(step, look)
                let layers = prViews(host.dots).flatMap { sdLayers($0.layer) }
                #expect(!layers.isEmpty, "\(look) / \(title): the view has no layers")
                #expect(!layers.contains { $0 is CAGradientLayer }, "\(look) / \(title): a gradient layer")
            }
        }
    }
}
