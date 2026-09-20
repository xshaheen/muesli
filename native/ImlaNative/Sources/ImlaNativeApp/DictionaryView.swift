import AppKit
import SwiftUI
import ImlaCore
import UniformTypeIdentifiers

private enum DictionaryRowMetrics {
    static let arrowWidth: CGFloat = 14
    static let thresholdWidth: CGFloat = 76
    static let actionButtonSize: CGFloat = ImlaTheme.compactControlHeight
    static let actionsWidth: CGFloat = actionButtonSize * 2 + ImlaTheme.spacing8
    static let suggestionPageSize = 10
}

struct DictionaryView: View {
    let appState: AppState
    let controller: ImlaController

    @State private var isAdding = false
    @State private var newWord = ""
    @State private var newReplacement = ""
    @State private var newThreshold = 0.85
    @State private var isShowingAccessibilityPrompt = false
    @State private var suggestionPage = 0
    @State private var dictionaryAlertMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing24) {
                header
                if !appState.config.dictionarySuggestions.isEmpty {
                    suggestionList
                }
                wordList
            }
            .padding(.horizontal, ImlaTheme.pageHorizontalInset)
            .padding(.top, ImlaTheme.pageTop)
            .padding(.bottom, ImlaTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ImlaTheme.backgroundBase)
        .onAppear {
            controller.reconcilePendingDictionaryCorrectionAccessibilityEnable()
        }
        .alert("Enable Accessibility?", isPresented: $isShowingAccessibilityPrompt) {
            Button("Cancel", role: .cancel) {
                controller.cancelDictionaryCorrectionAccessibilityEnableRequest()
            }
            Button("Enable") {
                controller.requestDictionaryCorrectionAccessibilityEnable()
            }
        } message: {
            Text("Dictionary suggestions briefly read focused app text via Accessibility after dictation. Grant access, then relaunch Imla to turn suggestions on.")
        }
        .alert(
            "Dictionary",
            isPresented: Binding(
                get: { dictionaryAlertMessage != nil },
                set: { if !$0 { dictionaryAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { dictionaryAlertMessage = nil }
        } message: {
            Text(dictionaryAlertMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            HStack {
                Spacer()
                Toggle(
                    "Dictionary suggestions",
                    isOn: Binding(
                        get: { appState.config.enableDictionaryCorrectionPrompts },
                        set: { handleDictionaryCorrectionPromptsToggle($0) }
                    )
                )
                .toggleStyle(.switch)
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textSecondary)
                .help("Briefly reads focused app text after dictation to detect corrections.")
                .featureTourTarget(.dictionarySuggestions)
                Button {
                    importDictionary()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(ImlaTheme.font(size: 12, weight: .medium))
                        .foregroundStyle(ImlaTheme.textPrimary)
                        .padding(.horizontal, ImlaTheme.spacing12)
                        .padding(.vertical, ImlaTheme.spacing8)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Import dictionary entries from a JSON file")
                Button {
                    exportDictionary()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(ImlaTheme.font(size: 12, weight: .medium))
                        .foregroundStyle(ImlaTheme.textPrimary)
                        .padding(.horizontal, ImlaTheme.spacing12)
                        .padding(.vertical, ImlaTheme.spacing8)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Export the current dictionary as JSON")
                Button {
                    isAdding = true
                    newWord = ""
                    newReplacement = ""
                    newThreshold = 0.85
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add new")
                            .font(ImlaTheme.font(size: 13, weight: .medium))
                    }
                    .foregroundStyle(ImlaTheme.textPrimary)
                    .padding(.horizontal, ImlaTheme.spacing12)
                    .padding(.vertical, ImlaTheme.spacing8)
                    .background(ImlaTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                            .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Text("Add custom words for names, brands, and domain terms, and tune how aggressively each entry should fuzzy-match transcription errors.")
                .font(ImlaTheme.body())
                .foregroundStyle(ImlaTheme.textSecondary)
        }
    }

    private func handleDictionaryCorrectionPromptsToggle(_ enabled: Bool) {
        if controller.setDictionaryCorrectionPromptsFromToggle(enabled) == .needsAccessibilityPermission {
            isShowingAccessibilityPrompt = true
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.title = "Import Imla Dictionary"
        panel.message = "Choose a JSON dictionary file"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        presentFilePanel(panel) { url in
            do {
                let data = try Data(contentsOf: url)
                let imported = try CustomWordDictionaryCodec.decode(data)
                let result = CustomWordDictionaryCodec.merge(
                    imported,
                    into: appState.config.customWords
                )
                controller.replaceCustomWords(result.words)

                let totalChanged = result.addedCount + result.updatedCount
                if totalChanged == 0 {
                    dictionaryAlertMessage = imported.isEmpty
                        ? "The selected dictionary did not contain any entries."
                        : "All dictionary entries were already present."
                } else {
                    var details = ["Imported \(result.addedCount) new", "updated \(result.updatedCount)"]
                    if result.skippedCount > 0 {
                        details.append("skipped \(result.skippedCount)")
                    }
                    dictionaryAlertMessage = details.joined(separator: ", ") + " dictionary entries."
                }
            } catch {
                dictionaryAlertMessage = "Could not import the dictionary. \(error.localizedDescription)"
            }
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.title = "Export Imla Dictionary"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "imla-dictionary.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        presentFilePanel(panel) { url in
            do {
                let data = try CustomWordDictionaryCodec.encode(appState.config.customWords)
                try data.write(to: url, options: .atomic)
                dictionaryAlertMessage = "Exported \(appState.config.customWords.count) dictionary entries."
            } catch {
                dictionaryAlertMessage = "Could not export the dictionary. \(error.localizedDescription)"
            }
        }
    }

    private func presentFilePanel(_ panel: NSSavePanel, onPick: @escaping (URL) -> Void) {
        NSApp.activate()
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                onPick(url)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                onPick(url)
            }
        }
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Suggested Corrections")
                        .font(ImlaTheme.headline())
                        .foregroundStyle(ImlaTheme.textPrimary)
                    Text("Corrections Imla noticed by briefly reading focused app text after dictation.")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, ImlaTheme.spacing16)
            .padding(.vertical, ImlaTheme.spacing12)

            Divider().background(ImlaTheme.surfaceBorder)

            ForEach(visibleDictionarySuggestions) { suggestion in
                DictionarySuggestionRow(suggestion: suggestion, controller: controller)
                Divider().background(ImlaTheme.surfaceBorder)
            }

            if suggestionPageCount > 1 {
                suggestionPaginationControls
            }
        }
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var visibleDictionarySuggestions: [DictionarySuggestion] {
        let suggestions = appState.config.dictionarySuggestions
        guard !suggestions.isEmpty else { return [] }
        let startIndex = boundedSuggestionPage * DictionaryRowMetrics.suggestionPageSize
        let endIndex = min(startIndex + DictionaryRowMetrics.suggestionPageSize, suggestions.count)
        return Array(suggestions[startIndex..<endIndex])
    }

    private var suggestionPageCount: Int {
        let count = appState.config.dictionarySuggestions.count
        guard count > 0 else { return 0 }
        return (count + DictionaryRowMetrics.suggestionPageSize - 1) / DictionaryRowMetrics.suggestionPageSize
    }

    private var boundedSuggestionPage: Int {
        min(max(suggestionPage, 0), max(suggestionPageCount - 1, 0))
    }

    private var suggestionRangeText: String {
        let count = appState.config.dictionarySuggestions.count
        guard count > 0 else { return "" }
        let start = boundedSuggestionPage * DictionaryRowMetrics.suggestionPageSize + 1
        let end = min(start + DictionaryRowMetrics.suggestionPageSize - 1, count)
        return "\(start)-\(end) of \(count)"
    }

    private var suggestionPaginationControls: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            Text(suggestionRangeText)
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textTertiary)

            Spacer()

            DictionaryIconButton(
                systemName: "chevron.left",
                label: "Previous suggestions",
                tint: ImlaTheme.textSecondary,
                isDisabled: boundedSuggestionPage == 0
            ) {
                suggestionPage = max(boundedSuggestionPage - 1, 0)
            }

            DictionaryIconButton(
                systemName: "chevron.right",
                label: "Next suggestions",
                tint: ImlaTheme.textSecondary,
                isDisabled: boundedSuggestionPage >= suggestionPageCount - 1
            ) {
                suggestionPage = min(boundedSuggestionPage + 1, max(suggestionPageCount - 1, 0))
            }
        }
        .padding(.horizontal, ImlaTheme.spacing16)
        .padding(.vertical, ImlaTheme.spacing8)
    }

    private var wordList: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider().background(ImlaTheme.surfaceBorder)

            if isAdding {
                addWordRow
                Divider().background(ImlaTheme.surfaceBorder)
            }

            if appState.config.customWords.isEmpty && !isAdding {
                emptyState
            } else {
                ForEach(appState.config.customWords) { word in
                    DictionaryWordEditorRow(word: word, controller: controller)
                    Divider().background(ImlaTheme.surfaceBorder)
                }
            }
        }
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: ImlaTheme.spacing8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(ImlaTheme.textTertiary)
            Text("No custom words yet")
                .font(ImlaTheme.body())
                .foregroundStyle(ImlaTheme.textSecondary)
            Text("Add words that transcription frequently gets wrong")
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(ImlaTheme.spacing32)
    }

    private var columnHeader: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            Text("Match")
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: DictionaryRowMetrics.arrowWidth)
            Text("Replace")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Threshold")
                .frame(width: DictionaryRowMetrics.thresholdWidth, alignment: .leading)
            Color.clear
                .frame(width: DictionaryRowMetrics.actionsWidth)
        }
        .font(ImlaTheme.caption())
        .foregroundStyle(ImlaTheme.textTertiary)
        .padding(.horizontal, ImlaTheme.spacing16)
        .padding(.vertical, ImlaTheme.spacing8)
    }

    private var addWordRow: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            TextField("Word", text: $newWord)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ImlaTheme.textTertiary)
                .frame(width: DictionaryRowMetrics.arrowWidth)
            TextField("Replace with", text: $newReplacement)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            ThresholdEditor(value: $newThreshold)
            DictionaryIconButton(
                systemName: "checkmark",
                label: "Add word",
                tint: ImlaTheme.accent,
                isDisabled: newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                let trimmedWord = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedWord.isEmpty else { return }
                let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                controller.addCustomWord(
                    CustomWord(
                        word: trimmedWord,
                        replacement: replacement.isEmpty ? nil : replacement,
                        matchingThreshold: newThreshold
                    )
                )
                isAdding = false
                newWord = ""
                newReplacement = ""
                newThreshold = 0.85
            }
            DictionaryIconButton(
                systemName: "xmark",
                label: "Cancel",
                tint: ImlaTheme.textTertiary
            ) {
                isAdding = false
                newWord = ""
                newReplacement = ""
                newThreshold = 0.85
            }
        }
        .padding(.horizontal, ImlaTheme.spacing16)
        .padding(.vertical, ImlaTheme.spacing12)
    }
}

private struct DictionarySuggestionRow: View {
    let suggestion: DictionarySuggestion
    let controller: ImlaController

    var body: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: ImlaTheme.spacing8) {
                    Text(suggestion.observed)
                        .font(ImlaTheme.body())
                        .foregroundStyle(ImlaTheme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ImlaTheme.textTertiary)
                    Text(suggestion.replacement)
                        .font(ImlaTheme.body())
                        .foregroundStyle(ImlaTheme.textPrimary)
                        .lineLimit(1)
                }
                Text(detailText)
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            DictionaryIconButton(
                systemName: "checkmark",
                label: "Add correction",
                tint: ImlaTheme.accent
            ) {
                controller.acceptDictionarySuggestion(id: suggestion.id)
            }
            DictionaryIconButton(
                systemName: "xmark",
                label: "Dismiss correction",
                tint: ImlaTheme.textTertiary
            ) {
                controller.dismissDictionarySuggestion(id: suggestion.id)
            }
        }
        .padding(.horizontal, ImlaTheme.spacing16)
        .padding(.vertical, ImlaTheme.spacing12)
    }

    private var detailText: String {
        var parts = ["Seen \(suggestion.occurrenceCount)x"]
        if !suggestion.appDisplayName.isEmpty {
            parts.append(suggestion.appDisplayName)
        }
        return parts.joined(separator: " | ")
    }
}

private struct DictionaryWordEditorRow: View {
    let word: CustomWord
    let controller: ImlaController

    @State private var draftWord: String
    @State private var draftReplacement: String
    @State private var draftThreshold: Double

    init(word: CustomWord, controller: ImlaController) {
        self.word = word
        self.controller = controller
        _draftWord = State(initialValue: word.word)
        _draftReplacement = State(initialValue: word.replacement ?? "")
        _draftThreshold = State(initialValue: word.matchingThreshold)
    }

    private var trimmedWord: String {
        draftWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        draftReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedWord != word.word
            || (trimmedReplacement.isEmpty ? nil : trimmedReplacement) != word.replacement
            || abs(draftThreshold - word.matchingThreshold) > 0.001
    }

    var body: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            TextField("Word", text: $draftWord)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ImlaTheme.textTertiary)
                .frame(width: DictionaryRowMetrics.arrowWidth)
            TextField("Replace with", text: $draftReplacement)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            ThresholdEditor(value: $draftThreshold)
            DictionaryIconButton(
                systemName: "checkmark",
                label: "Save word",
                tint: hasChanges && !trimmedWord.isEmpty ? ImlaTheme.accent : ImlaTheme.textTertiary,
                isDisabled: trimmedWord.isEmpty || !hasChanges
            ) {
                controller.updateCustomWord(
                    CustomWord(
                        id: word.id,
                        word: trimmedWord,
                        replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement,
                        matchingThreshold: draftThreshold
                    )
                )
            }
            DictionaryIconButton(
                systemName: "trash",
                label: "Delete word",
                tint: ImlaTheme.danger,
                weight: .regular
            ) {
                controller.removeCustomWord(id: word.id)
            }
        }
        .padding(.horizontal, ImlaTheme.spacing16)
        .padding(.vertical, ImlaTheme.spacing12)
    }
}

private struct ThresholdEditor: View {
    @Binding var value: Double

    @State private var isPresented = false
    @State private var draftPercent = ""

    private static let bounds = 0.70...0.99
    private static let sliderTint = Color.adaptive(dark: 0xFFFFFF, light: 0x000000)

    var body: some View {
        Button {
            draftPercent = Self.percentString(for: value)
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text(Self.label(for: value))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
                .font(ImlaTheme.mono(size: 11, weight: .medium))
                .foregroundStyle(ImlaTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ImlaTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                        .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .frame(width: DictionaryRowMetrics.thresholdWidth, alignment: .leading)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            thresholdPopover
        }
        .help("Matching threshold")
        .accessibilityLabel("Matching threshold")
        .accessibilityValue(Self.label(for: value))
    }

    private static func label(for value: Double) -> String {
        "\(Int(round(value * 100)))%"
    }

    private static func percentString(for value: Double) -> String {
        "\(Int(round(clamp(value) * 100)))"
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    private var thresholdPopover: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            HStack {
                Text("Threshold")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
                Spacer()
                HStack(spacing: 4) {
                    TextField("85", text: $draftPercent)
                        .textFieldStyle(.roundedBorder)
                        .font(ImlaTheme.mono(size: 12, weight: .medium))
                        .frame(width: 48)
                        .onSubmit(commitDraftPercent)
                    Text("%")
                        .font(ImlaTheme.font(size: 12, weight: .medium))
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
            }

            ThresholdSlider(
                value: Binding(
                    get: { Self.clamp(value) },
                    set: { newValue in
                        value = Self.clamp(newValue)
                        draftPercent = Self.percentString(for: value)
                    }
                ),
                bounds: Self.bounds,
                tint: Self.sliderTint
            )

            HStack {
                Text("70%")
                Spacer()
                Text("99%")
            }
            .font(ImlaTheme.mono(size: 10, weight: .medium))
            .foregroundStyle(ImlaTheme.textTertiary)
        }
        .padding(ImlaTheme.spacing16)
        .frame(width: 240)
        .onAppear {
            draftPercent = Self.percentString(for: value)
        }
        .onChange(of: value) { _, newValue in
            draftPercent = Self.percentString(for: newValue)
        }
    }

    private func commitDraftPercent() {
        let normalized = draftPercent.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard let percent = Double(normalized) else {
            draftPercent = Self.percentString(for: value)
            return
        }
        value = Self.clamp(percent / 100)
        draftPercent = Self.percentString(for: value)
    }
}

private struct ThresholdSlider: View {
    @Binding var value: Double

    let bounds: ClosedRange<Double>
    let tint: Color

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = progress(for: value)
            let thumbX = progress * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ImlaTheme.surfacePrimary)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(tint)
                    .frame(width: max(thumbX, thumbSize / 2), height: trackHeight)

                Circle()
                    .fill(tint)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: min(max(thumbX - thumbSize / 2, 0), width - thumbSize))
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateValue(locationX: gesture.location.x, width: width)
                    }
            )
        }
        .frame(height: thumbSize)
        .accessibilityElement()
        .accessibilityLabel("Matching threshold")
        .accessibilityValue("\(Int(round(value * 100)))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = clamped(value + 0.01)
            case .decrement:
                value = clamped(value - 0.01)
            @unknown default:
                break
            }
        }
    }

    private func progress(for value: Double) -> CGFloat {
        CGFloat((clamped(value) - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound))
    }

    private func updateValue(locationX: CGFloat, width: CGFloat) {
        let progress = min(max(Double(locationX / width), 0), 1)
        let rawValue = bounds.lowerBound + progress * (bounds.upperBound - bounds.lowerBound)
        value = clamped((rawValue * 100).rounded() / 100)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }
}

private struct DictionaryIconButton: View {
    let systemName: String
    let label: String
    let tint: Color
    var weight: Font.Weight = .bold
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: weight))
                .foregroundStyle(tint)
                .frame(
                    width: DictionaryRowMetrics.actionButtonSize,
                    height: DictionaryRowMetrics.actionButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
