// The kit's luminance reading of a picture region (S1.31: the panel follows the Light and Dark look).
//
//   lumastat <png> <x0> <y0> <x1> <y1>   prints "mean_luma <0-255> over <w> x <h> pixels"
//
// The four numbers are fractions of the picture (0 to 1, left to right, top to bottom). Every pixel of the
// region is read (the picture is drawn into a known RGBA layout first); the luminance of a pixel is
// 0.2126 R + 0.7152 G + 0.0722 B of its colour (alpha ignored: a window picture that kept its see-through
// edge still reads its colour), and the figure is the mean over the region.
// Exit codes: 0 read; 1 the file could not be read or the region is empty; 2 usage.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 5 else { fail("usage: lumastat <png> <x0> <y0> <x1> <y1>   (fractions 0 to 1)", 2) }
let fractions = args[1...4].compactMap { Double($0) }
guard fractions.count == 4, fractions.allSatisfy({ $0 >= 0 && $0 <= 1 }),
      fractions[0] < fractions[2], fractions[1] < fractions[3]
else { fail("usage: lumastat <png> <x0> <y0> <x1> <y1>   (four fractions 0 to 1, x0 < x1, y0 < y1)", 2) }

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

let x0 = Int(fractions[0] * Double(width)), x1 = Int(fractions[2] * Double(width))
let y0 = Int(fractions[1] * Double(height)), y1 = Int(fractions[3] * Double(height))
guard x1 > x0, y1 > y0 else { fail("the region holds no pixel") }

var sum = 0.0
var count = 0
for y in y0..<y1 {
    for x in x0..<x1 {
        let i = (y * width + x) * 4
        let alpha = Double(pixels[i + 3])
        guard alpha > 0 else { continue }
        // premultiplied: divide by alpha to get the colour itself
        let r = min(255.0, Double(pixels[i]) * 255.0 / alpha)
        let g = min(255.0, Double(pixels[i + 1]) * 255.0 / alpha)
        let b = min(255.0, Double(pixels[i + 2]) * 255.0 / alpha)
        sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
        count += 1
    }
}
guard count > 0 else { fail("every pixel of the region is fully see-through, so it has no colour to read") }
print(String(format: "mean_luma %.1f over %d x %d pixels", sum / Double(count), x1 - x0, y1 - y0))
