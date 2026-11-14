import CoreGraphics
import CoreText
import Foundation
import ImageIO

let width: CGFloat = 660
let height: CGFloat = 408
let iconY: CGFloat = 160
let grey: CGFloat = 118
let message = "Drag Sesame to the Applications folder to install"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func render(scale: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let pixelsWide = Int(width * scale)
    let pixelsHigh = Int(height * scale)
    guard let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not make a \(pixelsWide) x \(pixelsHigh) context")
    }
    ctx.scaleBy(x: scale, y: scale)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: height - y) }

    let level = grey / 255
    ctx.setFillColor(CGColor(colorSpace: space, components: [level, level, level, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!
    let arrow = CGMutablePath()
    arrow.move(to: pt(262, iconY - 7))
    arrow.addLine(to: pt(366, iconY - 7))
    arrow.addLine(to: pt(366, iconY - 24))
    arrow.addLine(to: pt(398, iconY))
    arrow.addLine(to: pt(366, iconY + 24))
    arrow.addLine(to: pt(366, iconY + 7))
    arrow.addLine(to: pt(262, iconY + 7))
    arrow.closeSubpath()
    ctx.setFillColor(white)
    ctx.addPath(arrow)
    ctx.fillPath()

    let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 20, nil)!
    let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, message as CFString, attributes as CFDictionary))
    let bounds = CTLineGetBoundsWithOptions(line, [])
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3,
                  color: CGColor(colorSpace: space, components: [0, 0, 0, 0.45])!)
    ctx.setFillColor(white)
    ctx.textPosition = pt((width - bounds.width) / 2 - bounds.minX, 62)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, dpi: Double, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
if args.count != 2 { fail("usage: make-dmg-background <output-dir>") }
let folder = URL(fileURLWithPath: args[1], isDirectory: true)

do {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
} catch {
    fail("could not make \(folder.path): \(error)")
}

let outputs: [(name: String, scale: CGFloat, dpi: Double)] = [("bg.png", 1, 72), ("bg@2x.png", 2, 144)]
for output in outputs {
    let target = folder.appendingPathComponent(output.name)
    let image = render(scale: output.scale)
    if !writePNG(image, dpi: output.dpi, to: target) { fail("could not write \(target.path)") }
    print("wrote \(target.path) (\(image.width) x \(image.height))")
}
