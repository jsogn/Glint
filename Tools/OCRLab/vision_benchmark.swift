import Foundation
import ImageIO
import Vision

struct Record: Decodable {
    let id: String
    let path: String
    let text: String
    let group: String
    let variant: String
}

struct Manifest: Decodable {
    let records: [Record]
}

struct Result: Encodable {
    let id: String
    let path: String
    let text: String
    let group: String
    let variant: String
    let raw: String
    let cleaned: String
    let confidence: Float
    let timesMs: [Double]
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let manifestURL = root.appendingPathComponent("Tools/OCRLab/data/manifest.json")
let outputURL = root.appendingPathComponent("Tools/OCRLab/results/vision.json")
let manifest = try JSONDecoder().decode(
    Manifest.self,
    from: Data(contentsOf: manifestURL)
)

func loadImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func clean(_ raw: String) -> String {
    String(raw.unicodeScalars.filter {
        CharacterSet.letters.contains($0)
    })
}

func recognize(_ image: CGImage) -> (String, Float) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return ("", 0)
    }
    let candidates = (request.results ?? []).compactMap {
        observation -> (String, Float)? in
        guard let best = observation.topCandidates(1).first else { return nil }
        return (best.string, best.confidence)
    }
    return candidates.max { $0.1 < $1.1 } ?? ("", 0)
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

if let first = manifest.records.first,
   let warmImage = loadImage(first.path) {
    for _ in 0..<5 {
        _ = recognize(warmImage)
    }
}

var output: [Result] = []
for record in manifest.records {
    guard let image = loadImage(record.path) else {
        fputs("cannot load \(record.path)\n", stderr)
        continue
    }
    var times: [Double] = []
    var recognized: (String, Float) = ("", 0)
    for _ in 0..<3 {
        let start = ContinuousClock.now
        recognized = recognize(image)
        times.append(milliseconds(start.duration(to: .now)))
    }
    output.append(
        Result(
            id: record.id,
            path: record.path,
            text: record.text,
            group: record.group,
            variant: record.variant,
            raw: recognized.0,
            cleaned: clean(recognized.0),
            confidence: recognized.1,
            timesMs: times
        )
    )
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(output).write(to: outputURL)
print("wrote \(output.count) results to \(outputURL.path)")
