// The kit's picture check: is a PNG blank?
//
//   pixelstat <png>      prints "<w> x <h> pixels, <n> distinct colours sampled"; exit 1 when blank
//   pixelstat <png> --colour <rrggbb>
//                        the control: prints how many percent of the sampled pixels match that colour; exit 1
//                        when fewer than 90 percent do
//
// The picture is drawn into a known RGBA layout, then a grid of at most about 40,000 pixels is
// sampled and the distinct colours are counted. Fewer than 16 distinct colours is blank: a screen
// that macOS would not let the terminal capture comes back as one flat colour or close to it.
// Exit codes: 0 not blank; 1 blank, or the file could not be read; 2 usage.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
let usageLine = "usage: pixelstat <png> [--colour <rrggbb>]"
guard args.count == 1 || args.count == 3 else { fail(usageLine, 2) }

// --colour <rrggbb>: the control mode. The picture passes when at least 90 percent of the sampled pixels are
// within 24 of that colour on every channel (a picture of the kit's own swatch window of a known colour).
var wanted: (Int, Int, Int)?
if args.count == 3 {
    guard args[1] == "--colour", args[2].count == 6, let hex = Int(args[2], radix: 16) else { fail(usageLine, 2) }
    wanted = ((hex >> 16) & 255, (hex >> 8) & 255, hex & 255)
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("cannot read \(args[0]) as a picture") }

let width = image.width
let height = image.height
guard width > 0, height > 0 else { fail("the picture has no pixels") }

var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else { fail("cannot draw the picture") }

let step = max(1, Int((Double(width * height) / 40_000).squareRoot()))
var colours = Set<UInt32>()
var sampled = 0
var matching = 0
var y = 0
while y < height {
    var x = 0
    while x < width {
        let i = (y * width + x) * 4
        colours.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        sampled += 1
        if let w = wanted,
           abs(Int(pixels[i]) - w.0) <= 24, abs(Int(pixels[i + 1]) - w.1) <= 24, abs(Int(pixels[i + 2]) - w.2) <= 24 {
            matching += 1
        }
        x += step
    }
    y += step
}

if let w = wanted {
    let percent = sampled == 0 ? 0 : matching * 100 / sampled
    let hex = String(format: "%02X%02X%02X", w.0, w.1, w.2)
    print("\(width) x \(height) pixels, \(percent) percent of the sampled pixels match #\(hex)")
    exit(percent >= 90 ? 0 : 1)
}

let blank = colours.count < 16
print("\(width) x \(height) pixels, \(colours.count) distinct colours sampled")
exit(blank ? 1 : 0)
