import AppKit
import Foundation
import Testing
@testable import Sesame

private let saScale = 4
private let saSide = 18 * saScale

private func saAlpha(_ state: MenuState) -> [[Int]]? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: saSide, pixelsHigh: saSide, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    context.cgContext.scaleBy(x: CGFloat(saScale), y: CGFloat(saScale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: 18, height: 18).fill(using: .copy)
    StatusIcons.image(for: state).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
    NSGraphicsContext.restoreGraphicsState()
    var rows: [[Int]] = []
    for y in 0..<saSide {
        var row: [Int] = []
        for x in 0..<saSide {
            let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            row.append(Int((alpha * 255).rounded()))
        }
        rows.append(row)
    }
    return rows
}

private struct SABox {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
}

private func saInk(_ grid: [[Int]], xRange: Range<Int> = 0..<saSide, yRange: Range<Int> = 0..<saSide) -> [(x: Int, y: Int)] {
    var points: [(x: Int, y: Int)] = []
    for y in yRange {
        for x in xRange where grid[y][x] > 127 { points.append((x, y)) }
    }
    return points
}

private func saBox(_ points: [(x: Int, y: Int)]) -> SABox? {
    guard let first = points.first else { return nil }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in points {
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    let s = Double(saScale)
    return SABox(minX: Double(minX) / s, maxX: Double(maxX + 1) / s, minY: Double(minY) / s, maxY: Double(maxY + 1) / s)
}

private func saRowSpan(_ grid: [[Int]], row: Int) -> (min: Double, max: Double)? {
    let xs = saInk(grid, yRange: row..<(row + 1)).map(\.x)
    guard let low = xs.min(), let high = xs.max() else { return nil }
    let s = Double(saScale)
    return (Double(low) / s, Double(high + 1) / s)
}

private let saBadgeStates: [(name: String, state: MenuState)] = [
    ("indexing", .indexing), ("paused", .paused), ("downloading", .downloading), ("failed", .failed),
]

@MainActor
@Suite("StatusIconArchTests", .serialized)
struct StatusIconArchTests {

    @Test func readyInkSitsLeftAndLowWithTheTopRightCornerEmpty() throws {
        let grid = try #require(saAlpha(.ready), "no bitmap")
        let points = saInk(grid)
        let box = try #require(saBox(points), "ready draws no ink")
        #expect(box.maxX <= 10, "ready ink reaches x = \(box.maxX) pt, want at most 10")
        #expect(box.minX >= 0, "ready ink starts at x = \(box.minX) pt")
        #expect(box.minY >= 3, "ready ink reaches up to y = \(box.minY) pt, want at least 3")
        #expect(box.maxY <= 18, "ready ink reaches down to y = \(box.maxY) pt")
        let cornerCount = saInk(grid, xRange: (12 * saScale)..<saSide, yRange: 0..<(6 * saScale)).count
        #expect(cornerCount == 0, "ready has \(cornerCount) ink pixels in the top-right 6 x 6 pt corner")
    }

    @Test func readyInkIsAnArchCentredAtTheTopAndAsWideAtTheBottomAsInTheMiddle() throws {
        let grid = try #require(saAlpha(.ready), "no bitmap")
        let box = try #require(saBox(saInk(grid)), "ready draws no ink")
        let topRow = Int((box.minY * Double(saScale)).rounded())
        let bottomRow = Int((box.maxY * Double(saScale)).rounded()) - 1
        let midRow = Int((((box.minY + box.maxY) / 2) * Double(saScale)).rounded())
        let top = try #require(saRowSpan(grid, row: topRow), "no ink in the top row")
        let mid = try #require(saRowSpan(grid, row: midRow), "no ink in the middle row")
        let bottom = try #require(saRowSpan(grid, row: bottomRow), "no ink in the bottom row")
        let spanCentre = (box.minX + box.maxX) / 2
        let topCentre = (top.min + top.max) / 2
        #expect(abs(topCentre - spanCentre) <= 1, "top row is centred at \(topCentre) pt, the arch span is centred at \(spanCentre) pt")
        let midWidth = mid.max - mid.min
        let bottomWidth = bottom.max - bottom.min
        #expect(abs(bottomWidth - midWidth) <= 1, "bottom row is \(bottomWidth) pt wide, middle row \(midWidth) pt")
    }

    @Test func theArchIsNineToElevenPointsWideAndTwelveToFourteenTall() throws {
        let grid = try #require(saAlpha(.ready), "no bitmap")
        let box = try #require(saBox(saInk(grid)), "ready draws no ink")
        let width = box.maxX - box.minX
        let height = box.maxY - box.minY
        #expect(width >= 9 && width <= 11, "arch is \(width) pt wide, want 9 to 11")
        #expect(height >= 12 && height <= 14, "arch is \(height) pt tall, want 12 to 14")
    }

    @Test func everyBadgeStateKeepsTheArchBitmapExactAndPutsItsBadgeTopRight() throws {
        let ready = try #require(saAlpha(.ready), "no bitmap")
        let split = 10 * saScale
        let badgeBottom = Int(8.25 * Double(saScale))
        for (name, state) in saBadgeStates {
            let grid = try #require(saAlpha(state), "\(name): no bitmap")
            var differing = 0
            for y in 0..<saSide {
                for x in 0..<split where grid[y][x] != ready[y][x] { differing += 1 }
            }
            #expect(differing == 0, "\(name): \(differing) pixels left of x = 10 pt differ from ready")
            let badge = saInk(grid, xRange: split..<saSide)
            let badgeCount = badge.count
            #expect(badgeCount > 0, "\(name): no badge ink right of x = 10 pt")
            let lowCount = badge.filter { $0.y >= badgeBottom }.count
            #expect(lowCount == 0, "\(name): \(lowCount) badge ink pixels at or below y = 8.25 pt")
        }
        let readyBadgeCount = saInk(ready, xRange: split..<saSide).count
        #expect(readyBadgeCount == 0, "ready has \(readyBadgeCount) ink pixels right of x = 10 pt")
    }
}
