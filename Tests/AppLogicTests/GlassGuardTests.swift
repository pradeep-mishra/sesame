import Foundation
import Testing

enum GlassScan {
    static let designPath = "Sesame/UI/Design.swift"
    static let guardMarkers = ["#available(macOS 26", "@available(macOS 26"]

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func mentionsGlass(_ line: String) -> Bool {
        line.contains("NSGlassEffectView")
            || line.contains("NSGlassEffectContainerView")
            || line.range(of: #"\.glass\b"#, options: .regularExpression) != nil
    }

    static func code(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
        if let comment = text.range(of: "//") { text = String(text[..<comment.lowerBound]) }
        return text
    }

    static func holdsMarker(_ index: Int, _ lines: [String]) -> Bool {
        var current = index
        while true {
            if guardMarkers.contains(where: { lines[current].contains($0) }) { return true }
            current -= 1
            guard current >= 0, lines[current].trimmingCharacters(in: .whitespaces).hasPrefix("@") else { return false }
        }
    }

    static func unguardedLines(_ lines: [String]) -> [Int] {
        var open: [Int] = []
        var bad: [Int] = []
        for (index, raw) in lines.enumerated() {
            if mentionsGlass(raw) {
                let covered = holdsMarker(index, lines) || open.contains { holdsMarker($0, lines) }
                if !covered { bad.append(index + 1) }
            }
            for character in code(raw) {
                if character == "{" {
                    open.append(index)
                } else if character == "}" {
                    _ = open.popLast()
                }
            }
        }
        return bad
    }

    static func read(_ root: URL, _ relative: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    static func violations(in root: URL) -> [String] {
        var out: [String] = []
        let sources = root.appendingPathComponent("Sources")
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: sources.path)) ?? []
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            let path = sources.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if text.contains("NSGlassEffectContainerView") { out.append("container: Sources/\(name)") }
            if text.contains("UIDesignRequiresCompatibility") { out.append("compat: Sources/\(name)") }
            let lines = text.components(separatedBy: "\n")
            if name == designPath {
                for number in unguardedLines(lines) { out.append("unguarded: Sources/\(name):\(number)") }
            } else {
                for (index, line) in lines.enumerated() where mentionsGlass(line) {
                    out.append("outside-design: Sources/\(name):\(index + 1)")
                }
            }
        }
        if read(root, "scripts/bundle.sh")?.contains("UIDesignRequiresCompatibility") != false {
            out.append("compat: scripts/bundle.sh")
        }
        if read(root, "Package.swift")?.contains("UIDesignRequiresCompatibility") != false {
            out.append("compat: Package.swift")
        }
        if read(root, "Package.swift")?.contains(".macOS(.v14)") != true {
            out.append("minimum-macos: Package.swift")
        }
        return out
    }

    static func plant(_ edit: (URL) throws -> Void) throws -> [String] {
        let fileManager = FileManager.default
        let real = repoRoot()
        let copy = fileManager.temporaryDirectory.appendingPathComponent("glass-guard-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: copy) }
        try fileManager.createDirectory(at: copy.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fileManager.copyItem(at: real.appendingPathComponent("Sources"), to: copy.appendingPathComponent("Sources"))
        try fileManager.copyItem(at: real.appendingPathComponent("scripts/bundle.sh"), to: copy.appendingPathComponent("scripts/bundle.sh"))
        try fileManager.copyItem(at: real.appendingPathComponent("Package.swift"), to: copy.appendingPathComponent("Package.swift"))
        try edit(copy)
        return violations(in: copy)
    }

    static func append(_ text: String, to relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        let existing = try String(contentsOf: url, encoding: .utf8)
        try (existing + "\n" + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func replace(_ old: String, with new: String, in relative: String, root: URL) throws {
        let url = root.appendingPathComponent(relative)
        let existing = try String(contentsOf: url, encoding: .utf8)
        try existing.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite("GlassGuardTests")
struct GlassGuardTests {
    let design = "Sources/Sesame/UI/Design.swift"
    let setupWindow = "Sources/Sesame/Setup/SetupWindow.swift"

    @Test func theRepositoryHoldsNoGlassOutsideDesignSwiftNoUnguardedGlassNoContainerNoCompatibilityKeyAndMinimumFourteen() {
        #expect(GlassScan.violations(in: GlassScan.repoRoot()) == [])
    }

    @Test func aCleanCopyOfTheRepositoryPassesTheScan() throws {
        #expect(try GlassScan.plant { _ in } == [])
    }

    @Test func aGlassViewNamedInAnotherSourceFileFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted() { _ = NSGlassEffectView() }", to: setupWindow, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("outside-design: Sources/Sesame/Setup/SetupWindow.swift") })
    }

    @Test func aGlassBezelInAnotherSourceFileFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted(_ b: NSButton) { b.bezelStyle = .glass }", to: setupWindow, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("outside-design: Sources/Sesame/Setup/SetupWindow.swift") })
    }

    @Test func aGlassViewInAnotherSourceFileFailsEvenInsideAnAvailabilityCheck() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted() { if #available(macOS 26, *) { _ = NSGlassEffectView() } }", to: setupWindow, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("outside-design: Sources/Sesame/Setup/SetupWindow.swift") })
    }

    @Test func theContainerViewFailsInAnotherSourceFile() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted() { _ = NSGlassEffectContainerView() }", to: setupWindow, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("container: Sources/Sesame/Setup/SetupWindow.swift") })
    }

    @Test func theContainerViewFailsInDesignSwiftEvenInsideAnAvailabilityCheck() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted() { if #available(macOS 26, *) { _ = NSGlassEffectContainerView() } }", to: design, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("container: Sources/Sesame/UI/Design.swift") })
    }

    @Test func aGlassViewAtTheTopLevelOfDesignSwiftFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("let planted = NSGlassEffectView()", to: design, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("unguarded: Sources/Sesame/UI/Design.swift") })
    }

    @Test func aGlassBezelInAnUnguardedFunctionOfDesignSwiftFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted(_ b: NSButton) {\n    b.bezelStyle = .glass\n}", to: design, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("unguarded: Sources/Sesame/UI/Design.swift") })
    }

    @Test func aGlassViewInTheElseBranchOfTheAvailabilityCheckFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted() {\n    if #available(macOS 26, *) {\n        _ = 1\n    } else {\n        _ = NSGlassEffectView()\n    }\n}", to: design, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("unguarded: Sources/Sesame/UI/Design.swift") })
    }

    @Test func aGlassViewInASiblingFunctionAfterAGuardedBlockFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func guarded() {\n    if #available(macOS 26, *) {\n        _ = NSGlassEffectView()\n    }\n}\nfunc sibling() {\n    _ = NSGlassEffectView()\n}", to: design, in: $0)
        }
        #expect(found.filter { $0.hasPrefix("unguarded: Sources/Sesame/UI/Design.swift") }.count == 1)
    }

    @Test func aGlassViewAndABezelInsideAnAvailabilityCheckInDesignSwiftPass() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("func planted(_ b: NSButton) {\n    if #available(macOS 26, *) {\n        _ = NSGlassEffectView()\n        b.bezelStyle = .glass\n    }\n}", to: design, in: $0)
        }
        #expect(found == [])
    }

    @Test func aGlassViewInAFunctionMarkedAvailableTwentySixInDesignSwiftPasses() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("@available(macOS 26, *)\nfunc planted() -> NSView {\n    NSGlassEffectView()\n}", to: design, in: $0)
        }
        #expect(found == [])
    }

    @Test func theCompatibilityKeyInASourceFileFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("let planted = \"UIDesignRequiresCompatibility\"", to: setupWindow, in: $0)
        }
        #expect(found.contains { $0.hasPrefix("compat: Sources/Sesame/Setup/SetupWindow.swift") })
    }

    @Test func theCompatibilityKeyInTheBundleScriptFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("echo UIDesignRequiresCompatibility", to: "scripts/bundle.sh", in: $0)
        }
        #expect(found.contains("compat: scripts/bundle.sh"))
    }

    @Test func theCompatibilityKeyInThePackageManifestFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.append("let planted = \"UIDesignRequiresCompatibility\"", to: "Package.swift", in: $0)
        }
        #expect(found.contains("compat: Package.swift"))
    }

    @Test func aPackageManifestWithoutMacOSFourteenFailsTheScan() throws {
        let found = try GlassScan.plant {
            try GlassScan.replace(".macOS(.v14)", with: ".macOS(.v15)", in: "Package.swift", root: $0)
        }
        #expect(found.contains("minimum-macos: Package.swift"))
    }
}
