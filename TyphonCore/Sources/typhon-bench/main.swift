import Foundation
import TyphonCore

// Usage: typhon-bench <model-dir> [ref.json] [--no-drafter] [--runs N]
// Compares Swift output with a reference JSON produced by dspark_mlx.py and prints latency.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: typhon-bench <model-dir> [ref.json] [--no-drafter] [--runs N]")
    exit(2)
}
let modelDir = URL(filePath: args[1])
let refPath = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : nil
let useDrafter = !args.contains("--no-drafter")
let runs = args.firstIndex(of: "--runs").flatMap { Int(args[$0 + 1]) } ?? 3

struct Case: Decodable { let input: String; let greedy: String; let dspark: String? }
let cases: [Case] =
    if let refPath, let data = FileManager.default.contents(atPath: refPath) {
        try JSONDecoder().decode([Case].self, from: data)
    } else {
        [Case(input: "cna u pikc up some milk on the way hoem", greedy: "Can you pick up some milk on the way home?", dspark: nil)]
    }

let engine = TyphonEngine()
let drafterDir = modelDir.appending(path: "dspark")
let loadStart = Date()
try await engine.load(
    modelDirectory: modelDir,
    drafterDirectory: useDrafter && FileManager.default.fileExists(atPath: drafterDir.path) ? drafterDir : nil)
print(String(format: "loaded in %.2fs (drafter: %@) footprint %.0f MB", Date().timeIntervalSince(loadStart),
             await engine.hasDrafter ? "yes" : "no", Double(MemoryReport.footprintBytes()) / 1_048_576))

var times: [Double] = []
var matches = 0
for c in cases {
    var last: Polished?
    for _ in 0..<runs {
        last = try await engine.polish(c.input)
        times.append(last!.milliseconds)
    }
    let ok = last!.output == c.greedy
    if ok { matches += 1 }
    print(String(format: "%6.1f ms %3d tok %@ %@", last!.milliseconds, last!.tokens, ok ? "✓" : "✗", last!.output))
    if !ok { print("          expected: \(c.greedy)") }
}
times.sort()
print(String(format: "median %.1f ms  p90 %.1f ms  identical %d/%d  footprint %.0f MB",
             times[times.count / 2], times[Int(Double(times.count) * 0.9)], matches, cases.count,
             Double(MemoryReport.footprintBytes()) / 1_048_576))

// Latest-wins check: fire 5 overlapping requests; only the last should complete.
let results = await withTaskGroup(of: String.self) { group in
    for i in 0..<5 {
        group.addTask {
            try? await Task.sleep(for: .milliseconds(i * 5))
            do { return "req\(i): " + (try await engine.polish(cases[i % cases.count].input)).output }
            catch { return "req\(i): \(error.localizedDescription)" }
        }
    }
    var all: [String] = []
    for await r in group { all.append(r) }
    return all.sorted()
}
results.forEach { print($0) }
