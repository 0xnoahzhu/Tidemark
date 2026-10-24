import Foundation
import FoundationModels

/// Structured answer the on-device model produces for one host.
///
/// Properties are generated in declaration order, so the model names the operator and writes the
/// summary before it commits to a category.
@Generable(description: "What a network host contacted by a Mac app is used for")
struct HostInsightVerdict: Equatable {
    @Guide(description: "Company or service that runs the host, such as GitHub, Cloudflare or Tencent. Leave empty when unknown.")
    var operatorName: String?

    @Guide(description: "At most two short sentences on what the app most likely uses this host for.")
    var summary: String

    @Guide(description: "Main purpose of the host. Use unknown when unsure.", .anyOf(HostCategory.allCases.map(\.rawValue)))
    var category: String

    @Guide(description: "One short sentence about tracking, advertising, analytics or unexpected data collection. Leave empty when there is nothing notable.")
    var concern: String?
}

extension HostInsightVerdict {
    /// Longest summary kept, in characters (a safety net on top of the two-sentence limit).
    static let summaryCharacterLimit = 320

    /// Converts the model output into the stored insight, validating the category and cleaning up text.
    func insight(host: String, languageCode: String, model: String?, now: Date = .now) -> HostInsight {
        let summary = Self.clampSentences(Self.cleaned(summary) ?? "", limit: 2)
        return HostInsight(
            host: host,
            category: Self.category(from: category),
            operatorName: Self.cleaned(operatorName),
            summary: summary,
            concern: Self.cleaned(concern),
            language: languageCode,
            model: model,
            createdAt: now
        )
    }

    /// Maps a raw category string to `HostCategory`; anything outside the allowed set becomes `.unknown`.
    static func category(from raw: String) -> HostCategory {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return HostCategory(rawValue: normalized) ?? .unknown
    }

    /// Trims whitespace and drops empty or placeholder answers (`none`, `unknown`, `n/a`, `-`).
    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = ["", "none", "unknown", "n/a", "na", "null", "nil", "-", "—", "no", "nothing"]
        let bare = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
        return placeholders.contains(bare) ? nil : trimmed
    }

    /// Keeps the first `limit` sentences of `text` (Latin and CJK sentence endings), capped at
    /// `summaryCharacterLimit` characters.
    static func clampSentences(_ text: String, limit: Int) -> String {
        let latinEnds: Set<Character> = [".", "!", "?"]
        let cjkEnds: Set<Character> = ["。", "！", "？"]
        var sentences = 0
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let isBoundary = cjkEnds.contains(character)
                || (latinEnds.contains(character) && (next == text.endIndex || text[next].isWhitespace))
            if isBoundary {
                sentences += 1
                if sentences == limit {
                    end = next
                    break
                }
            }
            index = next
        }
        var result = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > summaryCharacterLimit {
            result = String(result.prefix(summaryCharacterLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return result
    }
}
