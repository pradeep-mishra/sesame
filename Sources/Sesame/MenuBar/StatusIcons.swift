import AppKit

/// The menu bar icon for each state: an arched doorway, plus a small badge (none for Ready, a progress ring for Indexing, two
/// bars for Paused, a down arrow for Downloading, an exclamation mark for a failed download). Template images, so the system tints them for Light and Dark.
enum StatusIcons {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: MenuState) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            Design.templateInk.set()
            stroke(doorway(), width: 1.5)
            switch state {
            case .ready:
                break
            case .indexing:
                Design.templateInk(alpha: 0.35).set()
                stroke(arc(from: 0, to: 1), width: 1.5)
                Design.templateInk.set()
                stroke(arc(from: 0, to: 0.62), width: 1.5)
            case .paused:
                stroke(line([(12.6, 1.8), (12.6, 7.2)]), width: 1.8)
                stroke(line([(15.6, 1.8), (15.6, 7.2)]), width: 1.8)
            case .downloading:
                stroke(line([(14, 1.2), (14, 6.8)]), width: 1.6)
                stroke(line([(11.8, 4.6), (14, 7), (16.2, 4.6)]), width: 1.6)
            case .failed:
                stroke(line([(14, 1.2), (14, 5.2)]), width: 1.8)
                stroke(line([(14, 6.8), (14, 7)]), width: 1.8)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func line(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        return path
    }

    private static func doorway() -> NSBezierPath {
        let left: CGFloat = 1.5
        let right: CGFloat = 9.2
        let radius = (right - left) / 2
        let centreX = (left + right) / 2
        let centreY: CGFloat = 8.6
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left, y: 16.5))
        path.line(to: NSPoint(x: left, y: centreY))
        let steps = 24
        for step in 1...steps {
            let angle = Double.pi + Double.pi * Double(step) / Double(steps)
            path.line(to: NSPoint(x: centreX + radius * CGFloat(cos(angle)), y: centreY + radius * CGFloat(sin(angle))))
        }
        path.line(to: NSPoint(x: right, y: 16.5))
        return path
    }

    /// Part of the ring at the badge corner, from the top going clockwise; `from` and `to` are fractions of a turn.
    private static func arc(from: Double, to: Double) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = 48
        for step in 0...steps {
            let turn = from + (to - from) * Double(step) / Double(steps)
            let angle = -Double.pi / 2 + 2 * Double.pi * turn
            let point = NSPoint(x: 14 + 3 * cos(angle), y: 4.5 + 3 * sin(angle))
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        return path
    }
}
