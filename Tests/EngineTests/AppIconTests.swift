import CoreGraphics
import Foundation
import ImageIO
import Testing

private let iconProjectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let iconNames: [String] = [
    "icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
    "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png",
    "icon_512x512.png", "icon_512x512@2x.png",
]

private let iconSizes: [String: Int] = [
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32, "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256, "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
]

private let bigName = "icon_512x512@2x.png"

private struct IconPixel {
    let r: Int
    let g: Int
    let b: Int
    let a: Int
}

private struct IconImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func at(_ x: Int, _ y: Int) -> IconPixel {
        let i = (y * width + x) * 4
        return IconPixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }
}

private struct IconRan {
    let status: Int32
    let out: String
    let err: String
}

private func iconRun(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) -> IconRan {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("appicon-run-" + UUID().uuidString)
    let outURL = URL(fileURLWithPath: base.path + ".out")
    let errURL = URL(fileURLWithPath: base.path + ".err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
    }
    guard let outHandle = try? FileHandle(forWritingTo: outURL), let errHandle = try? FileHandle(forWritingTo: errURL) else {
        return IconRan(status: 125, out: "", err: "could not open capture files")
    }
    defer {
        try? outHandle.close()
        try? errHandle.close()
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = outHandle
    p.standardError = errHandle
    p.standardInput = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return IconRan(status: 127, out: "", err: "could not run \(exe): \(error)")
    }
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? outHandle.synchronize()
    try? errHandle.synchronize()
    let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    return IconRan(status: status, out: out, err: err)
}

private func iconDecode(_ path: String) -> IconImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let made: Bool = bytes.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: info) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    if !made { return nil }
    var i = 0
    while i < bytes.count {
        let a = Int(bytes[i + 3])
        if a > 0 && a < 255 {
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, (Int(bytes[i + c]) * 255 + a / 2) / a)) }
        }
        i += 4
    }
    return IconImage(width: w, height: h, bytes: bytes)
}

private func iconFolder(_ path: String) -> (names: [String], images: [String: IconImage]) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    var images: [String: IconImage] = [:]
    for n in names { if let img = iconDecode(path + "/" + n) { images[n] = img } }
    return (names, images)
}

private struct IcnsReport {
    let exists: Bool
    let magic: String
    let declared: Int
    let actual: Int
    let readStatus: Int32
    let readOutput: String
    let names: [String]
    let images: [String: IconImage]
}

private func iconInspectIcns(_ path: String, work: String) -> IcnsReport {
    guard let data = FileManager.default.contents(atPath: path), data.count >= 8 else {
        return IcnsReport(exists: false, magic: "", declared: 0, actual: 0, readStatus: -1, readOutput: "", names: [], images: [:])
    }
    let b = [UInt8](data.prefix(8))
    let magic = String(bytes: b[0..<4], encoding: .isoLatin1) ?? ""
    let declared = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
    let back = work + "/back.iconset"
    let ran = iconRun("/usr/bin/iconutil", ["-c", "iconset", "-o", back, path])
    let folder = iconFolder(back)
    return IcnsReport(exists: true, magic: magic, declared: declared, actual: data.count, readStatus: ran.status,
                      readOutput: ran.out + ran.err, names: folder.names, images: folder.images)
}

private struct IconBuild {
    let failure: String?
    let compile: IconRan?
    let first: IconRan?
    let names: [String]
    let images: [String: IconImage]
    let second: IconRan?
    let secondNames: [String]
    let report: IcnsReport?
    let bigPngBytes: Int
}

private func iconBuild() -> IconBuild {
    let script = iconProjectRoot.appendingPathComponent("scripts/make-icon.swift").path
    guard FileManager.default.fileExists(atPath: script) else {
        return IconBuild(failure: "scripts/make-icon.swift does not exist", compile: nil, first: nil, names: [],
                         images: [:], second: nil, secondNames: [], report: nil, bigPngBytes: 0)
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("appicon-" + UUID().uuidString).path
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let tool = tmp + "/make-icon"
    let compile = iconRun("/usr/bin/xcrun",
                          ["swiftc", "-O", "-module-cache-path", tmp + "/modcache", "-o", tool, script],
                          env: ["CLANG_MODULE_CACHE_PATH": tmp + "/modcache"], limit: 580)
    guard compile.status == 0 else {
        return IconBuild(failure: "swiftc exited \(compile.status): \(compile.out)\(compile.err)", compile: compile, first: nil,
                         names: [], images: [:], second: nil, secondNames: [], report: nil, bigPngBytes: 0)
    }
    let set = tmp + "/out.iconset"
    let icns = tmp + "/AppIcon.icns"
    let first = iconRun(tool, [set, icns], limit: 300)
    let folder = iconFolder(set)
    let bigBytes = (try? FileManager.default.attributesOfItem(atPath: set + "/" + bigName)[.size] as? Int) ?? 0
    let report = iconInspectIcns(icns, work: tmp)
    let second = iconRun(tool, [set, tmp + "/second.icns"], limit: 300)
    let secondNames = ((try? FileManager.default.contentsOfDirectory(atPath: set)) ?? []).sorted()
    return IconBuild(failure: nil, compile: compile, first: first, names: folder.names, images: folder.images, second: second,
                     secondNames: secondNames, report: report, bigPngBytes: bigBytes)
}

private let built: IconBuild = iconBuild()

private func iconReady() -> IconBuild? {
    if let why = built.failure {
        Issue.record(Comment(rawValue: "the icon generator did not build: \(why)"))
        return nil
    }
    return built
}

private func iconBig(_ images: [String: IconImage], _ label: String) -> IconImage? {
    guard let img = images[bigName] else {
        Issue.record(Comment(rawValue: "\(label): \(bigName) is missing or does not decode"))
        return nil
    }
    return img
}

private func iconNear(_ got: Int, _ want: Int, _ tol: Int) -> Bool { abs(got - want) <= tol }

private func iconPin(_ img: IconImage, _ x: Int, _ y: Int, _ want: (Int, Int, Int), tol: Int, alpha: Int? = 255,
                     sourceLocation: SourceLocation = #_sourceLocation) {
    let p = img.at(x, y)
    let good = iconNear(p.r, want.0, tol) && iconNear(p.g, want.1, tol) && iconNear(p.b, want.2, tol)
        && (alpha == nil || p.a == alpha!)
    #expect(good, "pixel (\(x), \(y)) is (\(p.r), \(p.g), \(p.b), a \(p.a)), wanted \(want) within \(tol), alpha \(String(describing: alpha))",
            sourceLocation: sourceLocation)
}

private func iconText(_ relative: String) -> String? {
    try? String(contentsOf: iconProjectRoot.appendingPathComponent(relative), encoding: .utf8)
}

private func iconWork(_ body: (String) -> Void) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("appicon-work-" + UUID().uuidString).path
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    body(tmp)
}

private func checkIcns(_ r: IcnsReport, label: String, floor: Int) {
    #expect(r.exists, "\(label) does not exist or is shorter than 8 bytes")
    guard r.exists else { return }
    #expect(r.magic == "icns", "\(label) starts with \"\(r.magic)\", wanted icns")
    #expect(r.declared == r.actual, "\(label) declares length \(r.declared), the file is \(r.actual) bytes")
    #expect(r.actual > floor, "\(label) is \(r.actual) bytes, wanted more than \(floor)")
    #expect(r.readStatus == 0, "iconutil -c iconset on \(label) exited \(r.readStatus): \(r.readOutput)")
    #expect(r.names == iconNames.sorted(), "iconutil read back \(r.names) from \(label), wanted the ten names")
    for n in iconNames {
        guard let img = r.images[n], let want = iconSizes[n] else {
            Issue.record(Comment(rawValue: "read-back \(n) from \(label) is missing or does not decode"))
            continue
        }
        #expect(img.width == want && img.height == want, "read-back \(n) from \(label) is \(img.width) x \(img.height), wanted \(want) x \(want)")
    }
}

private func checkPinsAt1024(_ img: IconImage) {
    #expect(img.width == 1024 && img.height == 1024, "the big icon is \(img.width) x \(img.height), wanted 1024 x 1024")
    guard img.width == 1024 && img.height == 1024 else { return }
    #expect(img.at(0, 0).a == 0, "(0, 0) alpha is \(img.at(0, 0).a), wanted 0")
    iconPin(img, 512, 600, (255, 171, 36), tol: 6)
    iconPin(img, 512, 850, (55, 42, 15), tol: 6)
}

@Suite("AppIconTests")
struct AppIconTests {

    @Test("the generator compiles, runs with an iconset folder and an icns path, exits 0 and prints one line per file")
    func generatorRuns() {
        guard let b = iconReady(), let first = b.first else { return }
        #expect(b.compile?.status == 0, "swiftc exited \(String(describing: b.compile?.status))")
        #expect(first.status == 0, "make-icon exited \(first.status): \(first.out)\(first.err)")
        let lines = first.out.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 10, "make-icon printed \(lines.count) lines on standard output, wanted 10: \(first.out)")
    }

    @Test("the iconset folder holds exactly the ten icon names and nothing else")
    func iconsetNames() {
        guard let b = iconReady() else { return }
        #expect(b.names == iconNames.sorted(), "the iconset holds \(b.names), wanted exactly \(iconNames.sorted())")
    }

    @Test("each PNG decodes and is square at its table size, drawn at that size")
    func iconsetSizes() {
        guard let b = iconReady() else { return }
        for n in iconNames {
            guard let img = b.images[n], let want = iconSizes[n] else {
                Issue.record(Comment(rawValue: "\(n) is missing or does not decode"))
                continue
            }
            #expect(img.width == want && img.height == want, "\(n) is \(img.width) x \(img.height), wanted \(want) x \(want)")
        }
    }

    @Test("a second run into the same folder exits 0 and leaves the same ten names")
    func rerunnable() {
        guard let b = iconReady(), let second = b.second else { return }
        #expect(second.status == 0, "the second make-icon run exited \(second.status): \(second.out)\(second.err)")
        #expect(b.secondNames == iconNames.sorted(), "after the second run the iconset holds \(b.secondNames), wanted the ten names")
    }

    @Test("1024 corners and margin: the corner is transparent, the tile corner arc is opaque, outside the arc only shadow shows")
    func tileEdges() {
        guard let b = iconReady(), let img = iconBig(b.images, "tile edges") else { return }
        #expect(img.width == 1024 && img.height == 1024, "the big icon is \(img.width) x \(img.height), wanted 1024 x 1024")
        guard img.width == 1024 && img.height == 1024 else { return }
        #expect(img.at(0, 0).a == 0, "(0, 0) alpha is \(img.at(0, 0).a), wanted 0")
        #expect(img.at(158, 158).a == 255, "(158, 158) alpha is \(img.at(158, 158).a), wanted 255")
        #expect(img.at(105, 105).a < 90, "(105, 105) alpha is \(img.at(105, 105).a), wanted under 90")
    }

    @Test("1024 tile gradient: near the top (22, 23, 30), near the bottom (7, 8, 11), at the bottom edge about (6, 7, 10)")
    func tileGradient() {
        guard let b = iconReady(), let img = iconBig(b.images, "tile gradient"), img.width == 1024, img.height == 1024 else { return }
        iconPin(img, 512, 110, (22, 23, 30), tol: 4)
        iconPin(img, 180, 880, (7, 8, 11), tol: 4)
        iconPin(img, 512, 920, (6, 7, 10), tol: 8)
    }

    @Test("1024 doorway: amber in the middle, pale gold at the arch top, tile just above the arch, the left edge at x = 330")
    func doorway() {
        guard let b = iconReady(), let img = iconBig(b.images, "doorway"), img.width == 1024, img.height == 1024 else { return }
        iconPin(img, 512, 600, (255, 171, 36), tol: 6)
        let mid = img.at(512, 600)
        #expect(mid.r > 240 && mid.g > 150 && mid.g < 200 && mid.b < 70, "(512, 600) is not amber: (\(mid.r), \(mid.g), \(mid.b))")
        iconPin(img, 512, 330, (255, 231, 159), tol: 6)
        let above = img.at(512, 310)
        #expect(above.a == 255 && above.r < 40, "(512, 310) is (\(above.r), \(above.g), \(above.b), a \(above.a)), wanted a tile pixel with red under 40")
        let left = img.at(320, 650)
        #expect(left.a == 255 && left.r < 40, "(320, 650) is (\(left.r), \(left.g), \(left.b), a \(left.a)), wanted a tile pixel with red under 40")
        let inside = img.at(340, 650)
        #expect(inside.r > 200, "(340, 650) red is \(inside.r), wanted above 200")
    }

    @Test("1024 floor light: (55, 42, 15) inside the polygon, about (7, 8, 12) outside it on the same row, and brighter inside")
    func floorLight() {
        guard let b = iconReady(), let img = iconBig(b.images, "floor light"), img.width == 1024, img.height == 1024 else { return }
        iconPin(img, 512, 850, (55, 42, 15), tol: 6)
        iconPin(img, 240, 850, (7, 8, 12), tol: 4)
        let lit = img.at(512, 850).r
        let dark = img.at(240, 850).r
        #expect(lit - dark >= 30, "red at (512, 850) is \(lit) and at (240, 850) is \(dark), wanted at least 30 more inside the polygon")
    }

    @Test("1024 shadow: black, 30 to 70 alpha under the tile edge, 15 to 50 just past the shifted edge, under 8 far below")
    func shadow() {
        guard let b = iconReady(), let img = iconBig(b.images, "shadow"), img.width == 1024, img.height == 1024 else { return }
        let a930 = img.at(512, 930)
        let a940 = img.at(512, 940)
        let a980 = img.at(512, 980)
        #expect(a930.a >= 30 && a930.a <= 70, "(512, 930) alpha is \(a930.a), wanted 30 to 70")
        #expect(a940.a >= 15 && a940.a <= 50, "(512, 940) alpha is \(a940.a), wanted 15 to 50")
        #expect(a980.a < 8, "(512, 980) alpha is \(a980.a), wanted under 8")
        for p in [a930, a940, a980] where p.a > 0 {
            #expect(p.r < 4 && p.g < 4 && p.b < 4, "a shadow pixel is (\(p.r), \(p.g), \(p.b), a \(p.a)), wanted black")
        }
    }

    @Test("the 128 and 16 PNGs are drawn at their own size: transparent corner, opaque lit middle")
    func smallSizes() {
        guard let b = iconReady() else { return }
        if let img = b.images["icon_128x128.png"], img.width == 128, img.height == 128 {
            #expect(img.at(0, 0).a == 0, "128: (0, 0) alpha is \(img.at(0, 0).a), wanted 0")
            let m = img.at(64, 64)
            #expect(m.a == 255 && m.r > 240 && m.g >= 150 && m.g <= 240,
                    "128: (64, 64) is (\(m.r), \(m.g), \(m.b), a \(m.a)), wanted opaque with red above 240 and green 150 to 240")
        } else {
            Issue.record(Comment(rawValue: "icon_128x128.png is missing or is not 128 x 128"))
        }
        if let img = b.images["icon_16x16.png"], img.width == 16, img.height == 16 {
            #expect(img.at(0, 0).a == 0, "16: (0, 0) alpha is \(img.at(0, 0).a), wanted 0")
            let m = img.at(8, 8)
            #expect(m.a == 255 && m.r > 200, "16: (8, 8) is (\(m.r), \(m.g), \(m.b), a \(m.a)), wanted opaque with red above 200")
        } else {
            Issue.record(Comment(rawValue: "icon_16x16.png is missing or is not 16 x 16"))
        }
    }

    @Test("the generated icns: icns magic, big-endian length equals the file, bigger than its 1024 PNG, iconutil reads all ten back at the table sizes")
    func generatedIcns() {
        guard let b = iconReady() else { return }
        guard let r = b.report else {
            Issue.record(Comment(rawValue: "no icns was inspected"))
            return
        }
        checkIcns(r, label: "the generated icns", floor: max(20_000, b.bigPngBytes))
    }

    @Test("the committed Resources/AppIcon.icns: magic, length, read back ten names at the table sizes, and the 1024 read-back keeps the pins")
    func committedIcns() {
        let path = iconProjectRoot.appendingPathComponent("Resources/AppIcon.icns").path
        iconWork { work in
            let r = iconInspectIcns(path, work: work)
            checkIcns(r, label: "Resources/AppIcon.icns", floor: 20_000)
            if let big = iconBig(r.images, "Resources/AppIcon.icns read-back") { checkPinsAt1024(big) }
        }
    }

    @Test("Info.plist names the icon: CFBundleIconFile is AppIcon, no CFBundleIconName, plutil -lint passes, other keys keep their values")
    func infoPlist() {
        let path = iconProjectRoot.appendingPathComponent("Resources/Info.plist").path
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            Issue.record(Comment(rawValue: "Resources/Info.plist does not read as a dictionary"))
            return
        }
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon", "CFBundleIconFile is \(String(describing: plist["CFBundleIconFile"])), wanted AppIcon")
        #expect(plist["CFBundleIconName"] == nil, "CFBundleIconName is present, wanted absent")
        #expect(plist["CFBundleIdentifier"] as? String == "app.sesame.Sesame")
        #expect(plist["CFBundleExecutable"] as? String == "Sesame")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        let lint = iconRun("/usr/bin/plutil", ["-lint", path])
        #expect(lint.status == 0, "plutil -lint Resources/Info.plist exited \(lint.status): \(lint.out)\(lint.err)")
    }

    @Test("bundle.sh makes Contents/Resources, copies the icns there before the first codesign, and stops when the icns is missing")
    func bundleScript() {
        guard let text = iconText("scripts/bundle.sh") else {
            Issue.record(Comment(rawValue: "scripts/bundle.sh does not read"))
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        #expect(lines.contains { $0.hasPrefix("mkdir -p \"$app/Contents/Resources\"") },
                "bundle.sh has no mkdir -p \"$app/Contents/Resources\" line")
        let copyPattern = "^cp\\s+\"?\\S*Resources/AppIcon\\.icns\"?\\s+\"?\\S*Contents/Resources/AppIcon\\.icns\"?\\s*$"
        let copyIndex = lines.firstIndex { $0.range(of: copyPattern, options: .regularExpression) != nil }
        #expect(copyIndex != nil, "bundle.sh has no cp from Resources/AppIcon.icns to Contents/Resources/AppIcon.icns")
        let signIndex = lines.firstIndex { $0.hasPrefix("codesign") }
        #expect(signIndex != nil, "bundle.sh has no codesign line")
        if let c = copyIndex, let s = signIndex {
            #expect(c < s, "the icns cp is at line \(c) of the code lines, the first codesign at \(s); the cp must come first")
        }
        let checkIndex = lines.firstIndex {
            $0.range(of: "\\[ +(! +)?-f [^\\]]*Resources/AppIcon\\.icns[^\\]]* +\\]", options: .regularExpression) != nil
        }
        #expect(checkIndex != nil, "bundle.sh has no [ -f ...Resources/AppIcon.icns ] check")
        if let k = checkIndex {
            let window = lines[k..<min(lines.count, k + 4)].joined(separator: "\n")
            #expect(window.contains("exit 1"), "the AppIcon.icns check does not exit 1")
            #expect(window.contains("echo"), "the AppIcon.icns check prints no message")
        }
        let syntax = iconRun("/bin/bash", ["-n", iconProjectRoot.appendingPathComponent("scripts/bundle.sh").path])
        #expect(syntax.status == 0, "bash -n scripts/bundle.sh exited \(syntax.status): \(syntax.out)\(syntax.err)")
    }
}
