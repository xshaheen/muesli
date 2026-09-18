import SwiftUI

struct MeetingPreparationBanner: View {
    let status: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: ImlaTheme.spacing12) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Preparing transcription")

            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing transcription")
                    .font(ImlaTheme.font(size: 13, weight: .semibold))
                    .foregroundStyle(ImlaTheme.textPrimary)
                Text(status ?? "Meeting transcription will start shortly.")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: ImlaTheme.spacing12)

            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Cancel meeting preparation")
        }
        .padding(ImlaTheme.spacing12)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerLarge, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }
}
