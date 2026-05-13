import Foundation

enum ANSITextSanitizer {
    private static let oscPattern = try? NSRegularExpression(
        pattern: #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)"#
    )
    private static let csiPattern = try? NSRegularExpression(
        pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#
    )
    private static let stringPattern = try? NSRegularExpression(
        pattern: #"\u001B[PX^_].*?\u001B\\"#
    )
    private static let escapePatterns = [oscPattern, csiPattern, stringPattern].compactMap { $0 }

    static func readableText(from input: String) -> String {
        var text = input
        for expression in escapePatterns {
            text = replacing(expression: expression, in: text)
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text
    }

    private static func replacing(expression: NSRegularExpression, in text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

enum TerminalSelectionCleaner {
    static func pasteboardText(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let readable = ANSITextSanitizer.readableText(from: raw)
        let lines = cleanedTerminalLines(from: readable)
        return lines.joined(separator: "\n")
    }

    static func lastReplyText(from data: Data) -> String? {
        let raw = String(decoding: data, as: UTF8.self)
        let readable = ANSITextSanitizer.readableText(from: raw)
        let lines = cleanedTerminalLines(from: readable)
        return lastReplyText(fromCleanedLines: lines)
    }

    static func cleanedLines(from data: Data) -> [String] {
        let raw = String(decoding: data, as: UTF8.self)
        let readable = ANSITextSanitizer.readableText(from: raw)
        return cleanedTerminalLines(from: readable)
    }

    static func lastReplyText(fromCleanedLines lines: [String]) -> String? {
        let lines = lines.filter { !isTransientAgentLine($0) }
        guard !lines.isEmpty else { return nil }

        let meaningfulLastIndex = lines.indices.last { index in
            let line = lines[index]
            return !line.trimmingCharacters(in: .whitespaces).isEmpty
                && !isPromptLine(line)
                && !isTrailingStatusLine(line)
        }
        guard let meaningfulLastIndex else { return nil }

        let promptIndices = lines.indices.filter { isPromptLine(lines[$0]) }
        let range: ArraySlice<String>
        if let tailPrompt = promptIndices.first(where: { $0 > meaningfulLastIndex }) {
            let previousPrompt = promptIndices.last { $0 < tailPrompt }
            let start = (previousPrompt.map { $0 + 1 }) ?? lines.startIndex
            let end = max(start, tailPrompt)
            range = lines[start..<end]
        } else if let lastPrompt = promptIndices.last(where: { $0 < meaningfulLastIndex }) {
            let start = min(lastPrompt + 1, lines.endIndex)
            range = lines[start...meaningfulLastIndex]
        } else {
            let start = max(lines.startIndex, meaningfulLastIndex - 120)
            range = lines[start...meaningfulLastIndex]
        }

        let reply = trimEmptyEdges(Array(range).filter { !isTrailingStatusLine($0) })
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }

    private static func cleanedTerminalLines(from text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizeTerminalLine(String($0)) }
            .filter { !isZellijChromeLine($0) }
    }

    private static func normalizeTerminalLine(_ line: String) -> String {
        var normalized = line.replacingOccurrences(of: "\u{0}", with: "")
        normalized = normalized.replacingOccurrences(of: "\u{fffd}", with: "")
        normalized = normalized.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("│") || normalized.hasPrefix("┃") {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }
        if normalized.hasSuffix("│") || normalized.hasSuffix("┃") {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }
        return normalized
    }

    private static func trimEmptyEdges(_ lines: [String]) -> [String] {
        var start = 0
        var end = lines.count
        while start < end, lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        while end > start, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return Array(lines[start..<end])
    }

    private static func isZellijChromeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("Zellij (") {
            return true
        }
        if trimmed.hasPrefix("Ctrl +") || trimmed.contains(" Ctrl +") {
            return true
        }
        if trimmed.hasPrefix("┌") || trimmed.hasPrefix("└") || trimmed.hasPrefix("├") || trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") {
            return true
        }
        if isDividerLine(trimmed) {
            return true
        }
        if trimmed.contains(" MY FOCUS ") || trimmed.contains("SCROLL:") {
            return true
        }
        return false
    }

    private static func isPromptLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed == ">" || trimmed == "›" || trimmed == "❯" {
            return true
        }
        if trimmed.hasPrefix("> ") || trimmed.hasPrefix("› ") || trimmed.hasPrefix("❯ ") {
            return true
        }
        if trimmed.hasPrefix("[CAVEMAN]") {
            return true
        }
        return false
    }

    private static func isTrailingStatusLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("• Working") || trimmed.hasPrefix("• Done") || trimmed.hasPrefix("• Thinking") {
            return true
        }
        if trimmed.hasPrefix("● Working") || trimmed.hasPrefix("● Done") || trimmed.hasPrefix("● Thinking") {
            return true
        }
        if trimmed.hasPrefix("✻ ") {
            return true
        }
        if trimmed.contains(" esc to interrupt") {
            return true
        }
        if trimmed.hasPrefix("gpt-") || trimmed.hasPrefix("claude-") {
            return true
        }
        return false
    }

    private static func isTransientAgentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if isTrailingStatusLine(trimmed) || isDividerLine(trimmed) {
            return true
        }
        if trimmed == "───────────────────────────────────────────" {
            return true
        }
        return false
    }

    private static func isDividerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8 else { return false }
        let dividerScalars = Set("─━═-—_".unicodeScalars)
        return trimmed.unicodeScalars.allSatisfy { dividerScalars.contains($0) }
    }
}
