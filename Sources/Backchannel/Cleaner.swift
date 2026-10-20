import Foundation

/// Strips vocal disfluencies and drops lines that are only backchannel noise ("Mm-hmm.", "Yeah.").
enum Cleaner {
    private static let fillers = try! NSRegularExpression(
        pattern: #"(?i)(?:^|,?\s+)(u+m+|u+h+m*|e+r+m*|a+h+|h+m+|m+h+m+|m+)(?=[\s,.!?]|$),?"#)

    private static let backchannel: Set<String> = [
        "mm", "mmhmm", "mhm", "hmm", "uhhuh", "yeah", "yep", "yup", "okay", "ok", "right", "sure",
        "cool", "nice", "totally", "wow", "oh", "and", "so", "you", "thank", "thanks", "gracias", "bye",
    ]

    static func clean(_ raw: String) -> String? {
        let words = raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        if words.isEmpty || words.allSatisfy({ backchannel.contains($0) || isFiller($0) }) { return nil }

        var s = fillers.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        s = s.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        guard let first = s.first else { return nil }
        return first.uppercased() + s.dropFirst()
    }

    private static func isFiller(_ w: String) -> Bool {
        w.range(of: #"^(u+m+|u+h+m*|e+r+m*|a+h+|h+m+|m+h*m*)$"#, options: .regularExpression) != nil
    }
}
