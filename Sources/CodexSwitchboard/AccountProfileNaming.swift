import Foundation

enum AccountProfileNaming {
    static func sanitizedProfileName(_ raw: String) throws -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789@._+-")
        guard !lower.isEmpty,
              lower != ".",
              lower != "..",
              lower.allSatisfy({ allowed.contains($0) }) else {
            throw CodexAccountCaptureError.invalidProfileName
        }
        return lower
    }

    static func sanitizedKeySegment(_ raw: String) -> String? {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let chars = folded.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                return ch
            }
            return "-"
        }
        let slug = String(chars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !slug.isEmpty, slug != "?", slug != "unknown" else { return nil }
        return slug
    }
}
