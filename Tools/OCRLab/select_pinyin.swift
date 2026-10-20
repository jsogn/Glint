import Carbon
import Foundation

let targetID = CommandLine.arguments.dropFirst().first
    ?? "com.apple.inputmethod.SCIM.ITABC"
let properties = [
    kTISPropertyInputSourceID as String: targetID,
] as CFDictionary
guard let sources = TISCreateInputSourceList(
    properties,
    false
)?.takeRetainedValue() as? [TISInputSource],
      let source = sources.first else {
    fputs("Apple Pinyin input source not found\n", stderr)
    exit(1)
}
let status = TISSelectInputSource(source)
guard status == noErr else {
    fputs("failed to select Apple Pinyin: \(status)\n", stderr)
    exit(2)
}
print("selected \(targetID)")
