import Foundation

// Chinese source keys are extracted from the maintained English table so all
// shipped languages resolve the same keys. Keep both Chinese tables explicit:
// an absent table falls back to the development language (English), not the key.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let english = try String(
    contentsOf: resources.appendingPathComponent("en.lproj/Localizable.strings"),
    encoding: .utf8
)
let pattern = try NSRegularExpression(
    pattern: #"^"((?:\\.|[^"\\])*)"\s*=\s*"(?:\\.|[^"\\])*";"#,
    options: .anchorsMatchLines
)
let range = NSRange(english.startIndex..<english.endIndex, in: english)
let keys = pattern.matches(in: english, range: range).compactMap { match -> String? in
    guard let keyRange = Range(match.range(at: 1), in: english) else { return nil }
    return String(english[keyRange])
}
precondition(!keys.isEmpty && Set(keys).count == keys.count, "English keys must be nonempty and unique")

for (locale, transform) in [("zh-Hans", false), ("zh-Hant", true)] {
    var lines = ["/* Generated from en.lproj/Localizable.strings by Scripts/generate-chinese-localizations.swift. */"]
    lines += keys.map { key in
        let value = transform
            ? (key.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? key)
            : key
        return "\"\(key)\" = \"\(value)\";"
    }
    let path = resources.appendingPathComponent("\(locale).lproj/Localizable.strings")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
}
