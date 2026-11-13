import CoreGraphics
import Foundation
import ImageIO

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> [CGFloat] {
    [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha]
}

func gradient(_ space: CGColorSpace, _ stops: [(CGFloat, [CGFloat])]) -> CGGradient {
    let colors = stops.map { CGColor(colorSpace: space, components: $0.1)! } as CFArray
    var locations = stops.map { $0.0 }
    return CGGradient(colorsSpace: space, colors: colors, locations: &locations)!
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not make a \(pixels) pixel context")
    }
    let s = CGFloat(pixels) / 1024
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (1024 - y) * s) }

    let tileRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 32 * s,
                  color: CGColor(colorSpace: space, components: [0, 0, 0, 0.3])!)
    ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
    ctx.addPath(tile)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    let body = gradient(space, [(0, rgb(0x16171e)), (1, rgb(0x06070a))])
    ctx.drawLinearGradient(body, start: pt(0, 100), end: pt(0, 924), options: [])

    let floor = CGMutablePath()
    floor.move(to: pt(330, 770))
    floor.addLine(to: pt(694, 770))
    floor.addLine(to: pt(820, 924))
    floor.addLine(to: pt(204, 924))
    floor.closeSubpath()
    ctx.saveGState()
    ctx.addPath(floor)
    ctx.clip()
    let glow = gradient(space, [(0, rgb(0xffb81c, 0.4)), (1, rgb(0xffb81c, 0))])
    ctx.drawLinearGradient(glow, start: pt(0, 770), end: pt(0, 924), options: [])
    ctx.restoreGState()

    let door = CGMutablePath()
    door.move(to: pt(330, 770))
    door.addLine(to: pt(330, 500))
    door.addArc(center: pt(512, 500), radius: 182 * s, startAngle: .pi, endAngle: 0, clockwise: true)
    door.addLine(to: pt(694, 770))
    door.closeSubpath()
    ctx.saveGState()
    ctx.addPath(door)
    ctx.clip()
    let light = gradient(space, [(0, rgb(0xffe9a6)), (0.55, rgb(0xffb81c)), (1, rgb(0xff6a4d))])
    ctx.drawLinearGradient(light, start: pt(0, 318), end: pt(0, 770), options: [])
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
if args.count != 3 { fail("usage: make-icon <iconset-dir> <icns-path>") }
let iconset = URL(fileURLWithPath: args[1], isDirectory: true)
let icnsPath = args[2]

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not make \(iconset.path): \(error)")
}

for file in iconFiles {
    let target = iconset.appendingPathComponent(file.name)
    if !writePNG(render(pixels: file.pixels), to: target) { fail("could not write \(target.path)") }
    print("wrote \(target.path) (\(file.pixels) x \(file.pixels))")
}

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", "-o", icnsPath, iconset.path]
do {
    try tool.run()
} catch {
    fail("could not run iconutil: \(error)")
}
tool.waitUntilExit()
if tool.terminationStatus != 0 { fail("iconutil exited \(tool.terminationStatus)") }
