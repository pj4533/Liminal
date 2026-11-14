// Standalone prompt dumper, compiled by scripts/print-prompts.sh together with
// Liminal/Visual/Prompt/*.swift. Foundation only: if this stops compiling,
// someone added an app dependency to the prompt builder.

import Foundation

var count = 24
var seed: UInt64 = UInt64(Date().timeIntervalSince1970)
var jsonl = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "-n": count = Int(args.removeFirst()) ?? count
    case "-s": seed = UInt64(args.removeFirst()) ?? seed
    case "--jsonl": jsonl = true
    case "-h", "--help":
        print("usage: print-prompts.sh [-n 24] [-s SEED] [--jsonl]")
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
}

let problems = PromptLibrary.standard.validate()
if !problems.isEmpty {
    FileHandle.standardError.write(("library problems:\n" + problems.joined(separator: "\n") + "\n").data(using: .utf8)!)
    exit(1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
for spec in PromptBuilder().batch(count: count, seed: seed) {
    if jsonl {
        let data = try encoder.encode(spec)
        print(String(data: data, encoding: .utf8)!)
    } else {
        print(spec.text)
    }
}
