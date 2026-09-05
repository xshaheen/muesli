import SwiftUI

/// Editing rules for the custom-instructions field, kept pure so they are
/// testable without a view.
enum CustomInstructionsEditorRules {
    /// Keeps the draft as typed unless its trimmed length exceeds the cap; then
    /// drops trailing characters until it fits. Leading whitespace is preserved,
    /// so it never costs meaningful text, and a trailing space or newline the
    /// user just typed survives.
    static func truncated(_ draft: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > CustomInstructions.maxLength else { return draft }
        let leading = draft.prefix { $0.isWhitespace || $0.isNewline }
        return String(leading) + String(trimmed.prefix(CustomInstructions.maxLength))
    }

    /// True when persisting the draft would change the stored value.
    static func shouldCommit(draft: String, committed: String) -> Bool {
        CustomInstructions.normalized(draft) != CustomInstructions.normalized(committed)
    }

    /// The counter value: the trimmed length, which is what gets stored.
    static func count(_ draft: String) -> Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}

/// Multi-line editor for the user's standing preferences.
///
/// The live draft is never rewritten while typing (trimming a bound
/// `TextEditor` deletes the space or newline just entered). It commits the
/// normalized text after a short debounce, on focus loss, and on disappearance,
/// because SwiftUI cancels view-scoped tasks on removal.
struct CustomInstructionsEditor: View {
    let committed: String
    let onCommit: (String) -> Void

    private static let placeholder = "Add guidance like \u{201C}use British English,\u{201D} \u{201C}be concise,\u{201D} or any other preferences."
    private static let debounce: Duration = .milliseconds(600)

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(MuesliTheme.body())
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(minHeight: 96)
                    .padding(MuesliTheme.spacing8)
                    .background(MuesliTheme.backgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                            .strokeBorder(MuesliTheme.surfaceBorder)
                    )
                    .accessibilityLabel("Custom instructions")
                    .accessibilityHint("Standing preferences applied to dictation cleanup, meeting transcript cleanup, and meeting notes")

                if draft.isEmpty {
                    Text(Self.placeholder)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, MuesliTheme.spacing8 + 5)
                        .padding(.vertical, MuesliTheme.spacing8 + 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            HStack {
                Spacer()
                Text("\(CustomInstructionsEditorRules.count(draft)) / \(CustomInstructions.maxLength)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .monospacedDigit()
                    .accessibilityLabel("\(CustomInstructionsEditorRules.count(draft)) of \(CustomInstructions.maxLength) characters")
            }
        }
        .onAppear { draft = committed }
        .onChange(of: committed) { _, newValue in
            if !isFocused { draft = newValue }
        }
        .onChange(of: draft) { _, newValue in
            let bounded = CustomInstructionsEditorRules.truncated(newValue)
            if bounded != newValue { draft = bounded }
        }
        .task(id: draft) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            commitIfNeeded()
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitIfNeeded() }
        }
        .onDisappear { commitIfNeeded() }
    }

    private func commitIfNeeded() {
        guard CustomInstructionsEditorRules.shouldCommit(draft: draft, committed: committed) else { return }
        onCommit(CustomInstructions.normalized(draft))
    }
}
