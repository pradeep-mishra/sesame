import CLlama
import Foundation

// The helper modes: `encode`, `index` and `index bench`. With no argument it prints the llama.cpp build it is
// linked against, so the link is shown.
let llamaTag = "b11461"
let llamaCommit = "4d756bc"

if CommandLine.arguments.count > 1 {
    let rest = Array(CommandLine.arguments.dropFirst(2))
    switch CommandLine.arguments[1] {
    case "encode":
        runEncode(arguments: rest)
    case "index":
        // The test kit's fake embedder loads no model, so no model path goes on.
        let fake = ProcessInfo.processInfo.environment["SESAME_FAKE_EMBEDDER"] == "1"
        func value(of flag: String) -> String? {
            rest.firstIndex(of: flag).flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil }
        }
        let textModel = fake ? nil : value(of: "--text-model")
        let mmModel = fake ? nil : value(of: "--mm-model")
        if rest.first == "bench" {
            Bench.run(textModel: textModel, mmModel: mmModel)
        }
        runIndex(textModel: textModel, mmModel: mmModel)
    default:
        FileHandle.standardError.write(Data("SesameHelper: unknown mode \(CommandLine.arguments[1])\n".utf8))
        exit(2)
    }
}

// llama_max_devices() is a plain call into the linked library that starts no GPU backend.
print("SesameHelper llama.cpp \(llamaTag) (commit \(llamaCommit)) max devices \(llama_max_devices())")
