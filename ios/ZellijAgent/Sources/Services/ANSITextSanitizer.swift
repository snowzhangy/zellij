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
