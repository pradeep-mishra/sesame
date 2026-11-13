import Foundation
import Testing
import SesameEngine

// plan-1 review round A, tester step: finding N1 (key-name checks are case sensitive, and the `.env` prefix hides
// `.environment.png`). Written from the review report (N1), the spec's Goals line ("key and password files, by name
// and extension: .pem .key .p12 .pfx id_rsa* .env* *.kdbx") and the brief only. Product source read for names:
// Sources/SesameEngine/Rules.swift (`Rules.isKeyName`, `Rules.admit(path:)`) and Walker.walk. No expected value
// comes from them.
//
// The decisions these tests pin:
//   - Key-name checks ignore case: `ID_RSA`, `ID_RSA.txt`, `.ENV`, `.Env.local`, `SERVER.PEM`, `Cert.P12` are key names.
//   - `.env` matches the file named `.env` and names that start with `.env.` (any suffix) only. `.environment.png` and
//     `.envelope.jpg` are ordinary names and an ordinary photo is admitted.
// A conflict to read in the report: the sealed RulesTests pin `.envrc` as a key name, and "`.env` and `.env.<suffix>`
// only" would make it ordinary. This file says nothing about `.envrc`; the sealed test stays the authority until the
// controller decides.

private let refusedNames = [
    "ID_RSA", "ID_RSA.txt", "Id_Rsa.pub", "ID_RSA_backup", "ID_DSA", "ID_ECDSA", "Id_Ed25519",
    ".ENV", ".Env.local", ".ENV.production", ".Env.LOCAL.bak",
    "SERVER.PEM", "Cert.P12", "CLIENT.KEY", "Bundle.PFX", "VAULT.KDBX",
]

// Key names wearing a photo extension: what `Rules.admit` must refuse because of the name.
private let refusedPhotoNames = ["ID_RSA.png", "Id_Dsa.JPG", "ID_ED25519.gif", ".ENV.png", ".Env.local.jpeg"]

// Names that merely start with the letters `.env` (or are `.env`-like), plus a photo extension: ordinary.
private let ordinaryPhotoNames = [".environment.png", ".envelope.jpg", ".ENVIRONMENT.png", ".Envelope.JPG", ".envy.heic"]

private func scratch() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-rules-case-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath().path
}

@Suite("RulesKeyNameCaseTests")
struct RulesKeyNameCaseTests {

    @Test func keyNamesAreRefusedWhateverTheCase() {
        for name in refusedNames {
            #expect(Rules.isKeyName(name), "\(name) is a key or password name, whatever its case")
        }
    }

    @Test func theLowercaseSpellingsStayKeyNames() {
        // A guard that holds today: the case rule must not lose the plain names.
        for name in ["id_rsa", "id_rsa.txt", ".env", ".env.local", "server.pem", "cert.p12", "client.key", "bundle.pfx", "vault.kdbx"] {
            #expect(Rules.isKeyName(name), "\(name) is a key or password name")
        }
    }

    @Test func namesThatOnlyStartWithTheLettersDotEnvAreNotKeyNames() {
        for name in ordinaryPhotoNames + [".environment", ".envelope", ".ENVIRONMENT", ".envy"] {
            #expect(!Rules.isKeyName(name), "\(name) is not `.env` and does not start with `.env.`")
        }
    }

    @Test func admitRefusesKeyNamedPhotosWhateverTheCaseAndAdmitsTheDotEnvLookAlikes() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in refusedPhotoNames + ordinaryPhotoNames {
            try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: folder + "/" + name))
        }
        for name in refusedPhotoNames {
            #expect(Rules.admit(path: folder + "/" + name) == nil, "\(name) must be refused because of its name")
        }
        for name in ordinaryPhotoNames {
            let admitted = Rules.admit(path: folder + "/" + name)
            #expect(admitted?.kind == "photo", "\(name) is an ordinary photo and must be admitted, got \(String(describing: admitted?.kind))")
        }
    }

    // The file system under the tests can be case-insensitive (APFS here), where `.environment.png` and
    // `.ENVIRONMENT.png` are one file and a walk lists it once. So this walk tree uses names that differ by more than
    // case; the case twins stay in the admit test above, which only asks about names.
    @Test func aWalkListsTheDotEnvLookAlikesAndNoKeyNamedPhoto() throws {
        let walkOrdinary = [".environment.png", ".envelope.jpg", ".envy.heic", "plain.jpg"]
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in refusedPhotoNames + walkOrdinary {
            try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: folder + "/" + name))
        }
        let walked = Set(try Walker.walk(root: folder, mode: .read).map { ($0.path as NSString).lastPathComponent })
        // Compared as the walk returns them: by lowercase name, so a case-insensitive file system cannot matter.
        #expect(Set(walked.map { $0.lowercased() }) == Set(walkOrdinary.map { $0.lowercased() }),
                "a read walk should list exactly the ordinary photos, got \(walked.sorted())")
    }
}
