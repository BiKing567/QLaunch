import Foundation

public enum ReleaseNotesBlock: Equatable, Sendable {
    case header(level: Int, text: String)
    case divider
    case listItem(ordered: Bool, index: Int, text: String)
    case blockQuote(text: String)
    case codeBlock(code: String)
    case paragraph(text: String)
}

public enum ReleaseNotesMarkdownParser {
    public static func parse(_ markdown: String) -> [ReleaseNotesBlock] {
        var elements: [ReleaseNotesBlock] = []
        let lines = markdown.components(separatedBy: .newlines)
        var inCodeBlock = false
        var codeBuffer: [String] = []
        var currentParagraph: [String] = []

        func isCJK(_ char: Character) -> Bool {
            guard let scalar = char.unicodeScalars.first else { return false }
            let v = scalar.value
            return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x3000 && v <= 0x303F) || (v >= 0xFF00 && v <= 0xFFEF)
        }

        func joinParagraphLines(_ lines: [String]) -> String {
            guard !lines.isEmpty else { return "" }
            var result = lines[0]
            for i in 1..<lines.count {
                let prev = lines[i - 1]
                let curr = lines[i]
                if let lastChar = prev.last, let firstChar = curr.first,
                   isCJK(lastChar) && isCJK(firstChar) {
                    result += curr
                } else {
                    result += " " + curr
                }
            }
            return result
        }

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                let text = joinParagraphLines(currentParagraph)
                if !text.isEmpty {
                    elements.append(.paragraph(text: text))
                }
                currentParagraph.removeAll()
            }
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    inCodeBlock = false
                    elements.append(.codeBlock(code: codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                } else {
                    flushParagraph()
                    inCodeBlock = true
                    codeBuffer.removeAll()
                }
                continue
            }

            if inCodeBlock {
                codeBuffer.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                elements.append(.divider)
                continue
            }

            if trimmed.hasPrefix("#") {
                var level = 0
                for ch in trimmed {
                    if ch == "#" { level += 1 } else { break }
                }
                if level <= 6 && trimmed.dropFirst(level).starts(with: " ") {
                    flushParagraph()
                    let headerText = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                    elements.append(.header(level: level, text: headerText))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let quoteText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                elements.append(.blockQuote(text: quoteText))
                continue
            }

            // Bullet list items: "- ", "* ", "+ "
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                elements.append(.listItem(ordered: false, index: 0, text: String(trimmed.dropFirst(2))))
                continue
            }

            // Ordered list: "1. ", "2. ", etc.
            if let dotIndex = trimmed.firstIndex(of: ".") {
                let prefix = trimmed[..<dotIndex]
                if let num = Int(prefix), trimmed[dotIndex...].starts(with: ". ") {
                    flushParagraph()
                    let itemText = String(trimmed[trimmed.index(dotIndex, offsetBy: 2)...])
                    elements.append(.listItem(ordered: true, index: num, text: itemText))
                    continue
                }
            }

            // Indented continuation of list item or blockquote
            if (rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t")), let last = elements.last {
                switch last {
                case let .listItem(ordered, index, text):
                    let newText = isCJK(text.last ?? " ") && isCJK(trimmed.first ?? " ") ? text + trimmed : text + " " + trimmed
                    elements[elements.count - 1] = .listItem(ordered: ordered, index: index, text: newText)
                    continue
                case let .blockQuote(text):
                    let newText = isCJK(text.last ?? " ") && isCJK(trimmed.first ?? " ") ? text + trimmed : text + " " + trimmed
                    elements[elements.count - 1] = .blockQuote(text: newText)
                    continue
                default:
                    break
                }
            }

            currentParagraph.append(trimmed)
        }

        if inCodeBlock && !codeBuffer.isEmpty {
            elements.append(.codeBlock(code: codeBuffer.joined(separator: "\n")))
        }
        flushParagraph()
        return elements
    }
}
