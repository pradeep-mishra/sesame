// swift-tools-version: 6.2
import PackageDescription

// llama.cpp is built by scripts/build-llama.sh into third_party/llama.cpp/build
// (static, Metal, mtmd). The library names and folders below are the ones llama.cpp's own
// cmake build writes there; if one differs, the build stops and a fresh tester edits this file.
let llama = Context.packageDirectory + "/third_party/llama.cpp"
let llamaBuild = llama + "/build"

// Swift 6 language mode (package level) with strict concurrency named on every target, and the
// header folders for the CLlama module map (llama.h, ggml.h, mtmd.h).
let llamaHeaders: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .unsafeFlags([
        "-Xcc", "-I" + llama + "/include",
        "-Xcc", "-I" + llama + "/ggml/include",
        "-Xcc", "-I" + llama + "/tools/mtmd",
    ])
]

// The llama.cpp static libraries (linked once, through SesameEngine) and what they need.
let llamaLink: [LinkerSetting] = [
    .unsafeFlags([
        "-L" + llamaBuild + "/src",
        "-L" + llamaBuild + "/ggml/src",
        "-L" + llamaBuild + "/ggml/src/ggml-metal",
        "-L" + llamaBuild + "/ggml/src/ggml-blas",
        "-L" + llamaBuild + "/tools/mtmd",
    ]),
    .linkedLibrary("mtmd"),
    .linkedLibrary("llama"),
    .linkedLibrary("ggml"),
    .linkedLibrary("ggml-metal"),
    .linkedLibrary("ggml-blas"),
    .linkedLibrary("ggml-cpu"),
    .linkedLibrary("ggml-base"),
    .linkedLibrary("c++"),
    .linkedLibrary("sqlite3"),
    .linkedFramework("Accelerate"),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("Foundation"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreServices"),
    .linkedFramework("ImageIO"),
    .linkedFramework("PDFKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Vision"),
    .linkedFramework("Speech"),
]

// What only the app uses.
let appLink: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("SwiftUI"),
    .linkedFramework("Carbon"),
    .linkedFramework("ServiceManagement"),
    .linkedFramework("IOKit"),
    .linkedFramework("CryptoKit"),
]

let package = Package(
    name: "Sesame",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sesame", targets: ["Sesame"]),
        .executable(name: "SesameHelper", targets: ["SesameHelper"]),
        .library(name: "SesameEngine", targets: ["SesameEngine"]),
    ],
    targets: [
        // C module for the llama.cpp headers: a module map and one header, written by task plan-1-t8.
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),

        // Engine library, no UI: rules, reading, index, search, model files, protocol.
        .target(
            name: "SesameEngine",
            dependencies: ["CLlama"],
            swiftSettings: llamaHeaders,
            linkerSettings: llamaLink + [.linkedFramework("CryptoKit")]
        ),

        // The app: menu bar, panel, setup, settings.
        .executableTarget(
            name: "Sesame",
            dependencies: ["SesameEngine"],
            swiftSettings: llamaHeaders,
            linkerSettings: appLink
        ),

        // The helper binary with the `encode` and `index` modes.
        .executableTarget(
            name: "SesameHelper",
            dependencies: ["SesameEngine", "CLlama"],
            swiftSettings: llamaHeaders
        ),

        // Tests.
        .testTarget(
            name: "EngineTests",
            dependencies: ["SesameEngine", "SesameHelper"],
            exclude: ["Reference"],
            swiftSettings: llamaHeaders
        ),
        .testTarget(
            name: "AppLogicTests",
            dependencies: ["Sesame", "SesameEngine"],
            swiftSettings: llamaHeaders
        ),
        .testTarget(
            name: "GoldenTests",
            dependencies: ["SesameEngine"],
            swiftSettings: llamaHeaders
        ),
    ],
    swiftLanguageModes: [.v6]
)
