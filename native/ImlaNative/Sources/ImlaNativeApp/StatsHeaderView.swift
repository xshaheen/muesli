import SwiftUI
import ImlaCore

struct StatsHeaderView: View {
    let dictationStats: DictationStats
    let meetingStats: MeetingStats
    var showsMeetingStat = true
    var tracksInsightsFeatureTour = false
    let onSelect: (InsightsSection) -> Void

    @ViewBuilder
    var body: some View {
        if tracksInsightsFeatureTour {
            cards
                .featureTourTarget(.insightsEntry)
        } else {
            cards
        }
    }

    private var cards: some View {
        HStack(spacing: ImlaTheme.spacing16) {
            StatCard(
                icon: "flame.fill",
                iconColor: Color(hex: 0xF5A623),
                value: "\(dictationStats.currentStreakDays)",
                label: "day streak",
                accessibilityHint: "Open streak insights",
                action: { onSelect(.streak) }
            )
            StatCard(
                icon: "character.cursor.ibeam",
                iconColor: ImlaTheme.accent,
                value: formatWordCount(dictationStats.totalWords),
                label: "words dictated",
                accessibilityHint: "Open word activity insights",
                action: { onSelect(.words) }
            )
            StatCard(
                icon: "gauge.with.dots.needle.33percent",
                iconColor: ImlaTheme.success,
                value: String(format: "%.0f", dictationStats.averageWPM),
                label: "avg WPM",
                accessibilityHint: "Open speaking pace insights",
                action: { onSelect(.pace) }
            )
            if showsMeetingStat {
                StatCard(
                    icon: "person.2.fill",
                    iconColor: ImlaTheme.accent,
                    value: "\(meetingStats.totalMeetings)",
                    label: "meetings",
                    accessibilityHint: "Open meeting insights",
                    action: { onSelect(.meetings) }
                )
            }
        }
        .padding(.horizontal, ImlaTheme.spacing24)
        .padding(.vertical, ImlaTheme.spacing20)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    let accessibilityHint: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: ImlaTheme.spacing8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
                Text(value)
                    .font(ImlaTheme.title2())
                    .monospacedDigit()
                    .foregroundStyle(ImlaTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(ImlaTheme.spacing16)
            .background(isHovered ? ImlaTheme.backgroundHover : ImlaTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                    .strokeBorder(isHovered ? ImlaTheme.accent.opacity(0.38) : ImlaTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(InsightsStatButtonStyle(reduceMotion: reduceMotion))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help(accessibilityHint)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityHint(accessibilityHint)
    }
}

private struct InsightsStatButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
