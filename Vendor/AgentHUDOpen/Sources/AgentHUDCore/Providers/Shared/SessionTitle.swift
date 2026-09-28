import Foundation

public enum SessionTitle {
    /// Session title: first real user prompt, first line, trimmed to 60 characters. Skips slash-command/meta lines.
    public static func from(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        let collapsed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed
    }
}
