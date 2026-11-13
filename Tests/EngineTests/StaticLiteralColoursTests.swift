import Foundation
import Testing

private let realScript = KC.scripts + "/check-static.sh"
private let rule = "literal-colours"
private let designPath = "Sources/Sesame/UI/Design.swift"

private func statusOf(_ rule: String, _ output: String) -> String? {
    for line in KC.lines(output) where line.hasPrefix("STATIC \(rule) ") {
        return line.split(separator: " ").map(String.init).last
    }
    return nil
}

private func detail(of rule: String, _ output: String) -> [String] {
    var out: [String] = []
    var inside = false
    for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.hasPrefix("STATIC ") { inside = line.hasPrefix("STATIC \(rule) ") } else if inside, line.hasPrefix(" ") { out.append(line.trimmingCharacters(in: .whitespaces)) }
    }
    return out
}

private func withProject<T>(_ files: [String: String], _ body: (_ script: String) throws -> T) throws -> T {
    let root = try KC.tempDir("static-colours-")
    try FileManager.default.createDirectory(atPath: root + "/scripts", withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: realScript, toPath: root + "/scripts/check-static.sh")
    for (rel, text) in files { try KC.write(root + "/" + rel, text) }
    return try body(root + "/scripts/check-static.sh")
}

private func quick(_ script: String) throws -> KC.Ran {
    try KC.run("/bin/bash", [script, "--quick"], env: ["KIT_NO_EVIDENCE": "1"])
}

private let plain = ["Sources/Sesame/Other.swift": "import AppKit\nlet ink = NSColor.labelColor\n"]

@Suite("StaticLiteralColoursTests")
struct StaticLiteralColoursTests {
    @Test("the real tree: the rule literal-colours is printed and PASSes (plan 8 t1 to t8 cleared the literals), the run exits 0")
    func realTreeIsGreen() throws {
        let r = try KC.run("/bin/bash", [realScript, "--quick"], env: ["KIT_NO_EVIDENCE": "1"])
        #expect(statusOf(rule, r.output) == "PASS", "literal-colours is \(statusOf(rule, r.output) ?? "missing"): \(detail(of: rule, r.output))")
        #expect(r.status == 0, "--quick exited \(r.status): \(r.output.suffix(400))")
    }

    @Test("each literal colour form in a file of Sources/Sesame fails the rule and names the file and the line",
          arguments: [
              "NSColor(red: 1, green: 0, blue: 0, alpha: 1)",
              "NSColor.white",
              "NSColor.black",
              "NSColor(white: 0.5, alpha: 1)",
          ])
    func literalFails(form: String) throws {
        let files = plain.merging(["Sources/Sesame/Planted.swift": "import AppKit\nlet planted = \(form)\n"]) { a, _ in a }
        try withProject(files) { script in
            let r = try quick(script)
            #expect(statusOf(rule, r.output) == "FAIL", "\(form): literal-colours is \(statusOf(rule, r.output) ?? "missing")")
            #expect(detail(of: rule, r.output).contains { $0.contains("Sources/Sesame/Planted.swift:2") }, "\(form): no detail names Planted.swift:2: \(detail(of: rule, r.output))")
            #expect(r.status == 1, "\(form): --quick exited \(r.status)")
        }
    }

    @Test("a .white or .black member used as an NSColor value fails too")
    func memberFails() throws {
        for form in ["let a: NSColor = .white", "view.layer?.backgroundColor = NSColor.black.cgColor", "label.textColor = .black"] {
            let files = plain.merging(["Sources/Sesame/Planted.swift": "import AppKit\n\(form)\n"]) { a, _ in a }
            try withProject(files) { script in
                let r = try quick(script)
                #expect(statusOf(rule, r.output) == "FAIL", "\(form): literal-colours is \(statusOf(rule, r.output) ?? "missing")")
            }
        }
    }

    @Test("the same literals inside Sources/Sesame/UI/Design.swift pass, and a Design.swift of another folder is not exempt")
    func designIsTheOnePlace() throws {
        let body = "import AppKit\nenum Design {\n    static let ink = NSColor.black\n    static let paper = NSColor.white\n    static let odd = NSColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)\n    static let a: NSColor = .white\n}\n"
        try withProject(plain.merging([designPath: body]) { a, _ in a }) { script in
            let r = try quick(script)
            #expect(statusOf(rule, r.output) == "PASS", "Design.swift: literal-colours is \(statusOf(rule, r.output) ?? "missing"): \(detail(of: rule, r.output))")
        }
        for other in ["Sources/Sesame/Other/Design.swift", "Sources/Sesame/Design.swift", "Sources/Sesame/UI/Other/Design.swift"] {
            try withProject(plain.merging([other: body]) { a, _ in a }) { script in
                let r = try quick(script)
                #expect(statusOf(rule, r.output) == "FAIL", "\(other): literal-colours is \(statusOf(rule, r.output) ?? "missing")")
                #expect(detail(of: rule, r.output).contains { $0.contains(other) }, "\(other): no detail names it")
            }
        }
    }

    @Test("the rule is not over broad: semantic colours, comments, strings, and names that only contain white or black pass")
    func notOverBroad() throws {
        let text = """
        import AppKit
        // NSColor.white and NSColor(red: 1, green: 1, blue: 1, alpha: 1) are only a comment here
        let a = NSColor.labelColor
        let b = NSColor.controlAccentColor.withAlphaComponent(0.5)
        let c = "NSColor.white .black"
        let d = Design.templateInk
        let e = CharacterSet.whitespaces
        let f = whiteBalance + blackLevel
        let g = view.whiteSpaceCount
        """
        try withProject(plain.merging(["Sources/Sesame/Quiet.swift": text]) { a, _ in a }) { script in
            let r = try quick(script)
            #expect(statusOf(rule, r.output) == "PASS", "literal-colours is \(statusOf(rule, r.output) ?? "missing"): \(detail(of: rule, r.output))")
        }
    }

    @Test("the rule reads only Sources/Sesame: a literal in another target is not this rule's business")
    func otherTargetsAreOut() throws {
        let files = plain.merging(["Sources/SesameEngine/Odd.swift": "let a = NSColor.white\n"]) { a, _ in a }
        try withProject(files) { script in
            let r = try quick(script)
            #expect(statusOf(rule, r.output) == "PASS", "literal-colours is \(statusOf(rule, r.output) ?? "missing")")
        }
    }

    @Test("the allowlist names the one exempt path, in the script and in static-allowlist.txt, and kit-privacy.sh agrees")
    func allowlist() throws {
        let line = "\(rule) \(designPath)"
        let printed = try KC.run("/bin/bash", [realScript, "--allowlist"])
        #expect(KC.lines(printed.output).contains(line), "check-static.sh --allowlist lacks `\(line)`: \(printed.output)")
        let file = KC.lines(KC.read(KC.lib + "/static-allowlist.txt") ?? "")
        #expect(file.contains(line), "static-allowlist.txt lacks `\(line)`")
        let kit = try KC.kitRoot()
        let r = try KC.run("/bin/bash", [KC.scripts + "/kit-privacy.sh", "static-allowlist"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
        #expect(r.status == 0 && r.output.contains("ALLOWLIST OK"), "kit-privacy.sh static-allowlist: \(r.status) \(r.output)")
    }

    @Test("--selftest plants a literal colour in a copy and sees the rule go red")
    func selftestPlant() throws {
        let tmp = try KC.tempDir("static-colours-self-")
        let r = try KC.run("/bin/bash", [realScript, "--selftest"], env: ["TMPDIR": tmp + "/", "KIT_NO_EVIDENCE": "1"])
        #expect(r.status == 0, "--selftest exited \(r.status): \(r.output.suffix(500))")
        #expect(KC.lines(r.output).contains("SELFTEST literal-colour-elsewhere RED"), "no `SELFTEST literal-colour-elsewhere RED`: \(r.output.suffix(500))")
        #expect(KC.lines(r.output).contains("SELFTEST OK"), "no SELFTEST OK")
    }

    @Test("the rule order puts literal-colours last: eighteen STATIC lines in a quick run")
    func eighteenRules() throws {
        let r = try KC.run("/bin/bash", [realScript, "--quick"], env: ["KIT_NO_EVIDENCE": "1"])
        let rules = KC.lines(r.output).filter { $0.hasPrefix("STATIC ") && !$0.hasPrefix("STATIC-RESULT") }.map { $0.split(separator: " ")[1] }
        #expect(rules.count == 18 && rules.last == "literal-colours", "the STATIC lines are \(rules)")
    }
}
