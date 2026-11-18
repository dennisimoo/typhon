import SwiftUI
import TyphonCore

/// The suggestion bubble: the fixed text with changes highlighted, plus key hints.
struct SuggestionView: View {
    let content: PanelContent?
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 8) {
                DiffText(segments: content.segments)
                    .font(.system(size: 13.5))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(perform: onAccept)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Accepts the suggestion")

                HStack(spacing: 10) {
                    KeyHint(key: "tab", label: content.acceptLabel)
                    KeyHint(key: "esc", label: "Dismiss")
                    Spacer(minLength: 12)
                    Text(timingLabel(for: content))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss suggestion")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minWidth: 240, alignment: .leading)
            .opacity(content.isStale ? 0.6 : 1)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(6) // room for the glass edge highlight
            .animation(.smooth(duration: 0.18), value: content)
        }
    }
}

private func timingLabel(for content: PanelContent) -> String {
    if content.isStale { return "updating…" }
    if content.milliseconds > 0 { return "\(Int(content.milliseconds.rounded())) ms" }
    return "preview"
}

/// Renders a word diff: removed words struck through, added words highlighted.
struct DiffText: View {
    let segments: [DiffSegment]

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                piece.foregroundColor = .primary
            case .removed:
                // Keep the trailing space outside the strike so words don't run together.
                let trimmed = segment.text.trimmingCharacters(in: .whitespaces)
                piece = AttributedString(trimmed)
                piece.strikethroughStyle = .single
                piece.foregroundColor = .secondary
                result.append(piece)
                piece = AttributedString(" ")
            case .added:
                piece.foregroundColor = .accentColor
                piece.font = .system(size: 13.5, weight: .semibold)
            }
            result.append(piece)
        }
        return result
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.quaternary, in: .rect(cornerRadius: 4))
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SuggestionView(
        content: PanelContent(
            segments: WordDiff.diff("cna u pikc up some milk on the way hoem", "Can you pick up some milk on the way home?"),
            milliseconds: 58, isStale: false, acceptLabel: "Accept"),
        onAccept: {}, onDismiss: {})
    .padding(40)
}
