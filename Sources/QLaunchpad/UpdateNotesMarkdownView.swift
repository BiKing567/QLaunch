import AppKit
import QLaunchpadCore
import SwiftUI

struct UpdateNotesMarkdownView: View {
    let elements: [ReleaseNotesBlock]

    init(markdown: String) {
        self.elements = ReleaseNotesMarkdownParser.parse(markdown)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(elements.enumerated()), id: \.offset) { i, el in
                    switch el {
                    case let .header(level, text):
                        let font: Font = {
                            switch level {
                            case 1: return .system(size: 15.5, weight: .bold)
                            case 2: return .system(size: 14.5, weight: .bold)
                            case 3: return .system(size: 13.5, weight: .semibold)
                            default: return .system(size: 12.5, weight: .semibold)
                            }
                        }()
                        Text(inlineMarkdown(text))
                            .font(font)
                            .foregroundStyle(.primary)
                            .padding(.top, i > 0 ? 5 : 0)

                    case .divider:
                        Divider()
                            .padding(.vertical, 3)

                    case let .listItem(ordered, index, text):
                        HStack(alignment: .top, spacing: 6) {
                            Text(ordered ? "\(index)." : "•")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: ordered ? 16 : 8, alignment: .trailing)
                            Text(inlineMarkdown(text))
                                .font(.system(size: 12.5))
                                .lineSpacing(2)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                    case let .blockQuote(text):
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: 3)
                            Text(inlineMarkdown(text))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                        }
                        .padding(.vertical, 2)

                    case let .codeBlock(code):
                        Text(code)
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5)
                            )

                    case let .paragraph(text):
                        Text(inlineMarkdown(text))
                            .font(.system(size: 12.5))
                            .lineSpacing(2.5)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 450, height: 250)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
        )
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(text)
        }
    }
}
