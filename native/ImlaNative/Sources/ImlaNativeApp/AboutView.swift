import SwiftUI
import ImlaCore

struct AboutView: View {
    let appState: AppState
    let onOpenManualDiagnosticReport: () -> Void
    let onSetAutomaticDiagnosticIssuePrompts: (Bool) -> Void

    private let githubURL = "https://github.com/xshaheen/muesli"
    private let donateURL = "https://buymeacoffee.com/phequals7"
    private let actionButtonWidth: CGFloat = 136

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        return "v\(v)"
    }

    private var appDataPath: String {
        AppIdentity.supportDirectoryURL.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing32) {

                if let banner = updateBanner {
                    updateBannerView(banner)
                }

                // MARK: - App Info
                sectionHeader("App Info")
                aboutCard {
                    aboutRow("Version") {
                        Text(version)
                            .font(ImlaTheme.mono(size: 15, weight: .semibold))
                            .foregroundStyle(ImlaTheme.textPrimary)
                    }

                    Divider().background(ImlaTheme.surfaceBorder)

                    aboutRow("Updates") {
                        Text(updateRowGuidance)
                            .font(ImlaTheme.callout())
                            .foregroundStyle(ImlaTheme.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // MARK: - Support
                sectionHeader("Support")
                aboutCard {
                    aboutRow("Support Development") {
                        Button {
                            if let url = URL(string: donateURL) { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 12))
                                Text("Donate")
                                    .font(ImlaTheme.font(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, ImlaTheme.spacing20)
                            .padding(.vertical, ImlaTheme.spacing8)
                            .frame(width: actionButtonWidth)
                            .background(ImlaTheme.success)
                            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().background(ImlaTheme.surfaceBorder)

                    aboutRow("Source Code") {
                        actionButton("GitHub", icon: "arrow.up.right.square") {
                            if let url = URL(string: githubURL) { NSWorkspace.shared.open(url) }
                        }
                    }

                    Divider().background(ImlaTheme.surfaceBorder)

                    aboutRow("Report a Problem") {
                        actionButton("Open Report", icon: "exclamationmark.bubble") {
                            onOpenManualDiagnosticReport()
                        }
                    }

                    Divider().background(ImlaTheme.surfaceBorder)

                    aboutRow("Automatic issue reporting prompts") {
                        Toggle("Auto reporting", isOn: Binding(
                            get: { appState.config.enableAutomaticDiagnosticIssuePrompts },
                            set: onSetAutomaticDiagnosticIssuePrompts
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("Suggest an anonymized GitHub issue after an app error")
                        .accessibilityLabel("Automatic issue reporting prompts")
                    }
                }

                // MARK: - Data
                sectionHeader("Data")
                aboutCard {
                    VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                        Text("App Data Directory")
                            .font(ImlaTheme.body())
                            .foregroundStyle(ImlaTheme.textPrimary)

                        HStack {
                            Text(appDataPath)
                                .font(ImlaTheme.mono(size: 12))
                                .foregroundStyle(ImlaTheme.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            actionButton("Open", icon: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appDataPath)
                            }
                        }
                    }
                }

                // MARK: - Acknowledgements
                sectionHeader("Acknowledgements")
                aboutCard {
                    acknowledgement(
                        name: "FluidAudio by FluidInference",
                        description: "CoreML speech stack powering Parakeet, Silero VAD, and speaker diarization on Apple Silicon."
                    )
                    Divider().background(ImlaTheme.surfaceBorder)
                    acknowledgement(
                        name: "LocalVQE by localai-org",
                        description: "On-device acoustic echo cancellation powering cleaner meeting transcription."
                    )
                    Divider().background(ImlaTheme.surfaceBorder)
                    acknowledgement(
                        name: "WhisperKit by Argmax",
                        description: "Swift Whisper inference on CoreML/ANE powering the app's Whisper Small, Medium, and Large Turbo backends."
                    )
                }

                Spacer(minLength: ImlaTheme.spacing32)
            }
            .padding(.horizontal, ImlaTheme.pageHorizontalInset)
            .padding(.top, ImlaTheme.pageTop)
            .padding(.bottom, ImlaTheme.spacing32)
        }
        .background(ImlaTheme.backgroundBase)
    }

    // MARK: - Components

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ImlaTheme.font(size: 11, weight: .semibold))
            .foregroundStyle(ImlaTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    @ViewBuilder
    private func aboutCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(ImlaTheme.spacing20)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private struct UpdateBanner {
        let icon: String
        let title: String
        let message: String
        let tint: Color
    }

    private var updateRowGuidance: String {
        switch appState.sparkleUpdateStatus {
        case .available:
            return "Use the menu bar icon > Check for Updates..."
        case .downloaded:
            return "Use the menu bar updater to finish installation."
        case .checking, .busy, .installing:
            return "Checking..."
        case .failed:
            return "Use the menu bar icon > Check for Updates..."
        case .idle, .upToDate, .disabled:
            return "Use the menu bar icon > Check for Updates..."
        }
    }

    private var updateBanner: UpdateBanner? {
        switch appState.sparkleUpdateStatus {
        case .idle:
            return nil
        case .checking:
            return UpdateBanner(
                icon: "arrow.triangle.2.circlepath",
                title: "Checking for updates",
                message: "Imla is checking the appcast for the latest version.",
                tint: ImlaTheme.transcribing
            )
        case .busy(let message):
            return UpdateBanner(
                icon: "clock.arrow.circlepath",
                title: "Updater is busy",
                message: message,
                tint: ImlaTheme.transcribing
            )
        case .available(let version):
            return UpdateBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Imla \(version) is available",
                message: "An update is available. Use the menu bar icon > Check for Updates... to open the updater.",
                tint: ImlaTheme.transcribing
            )
        case .downloaded(let version):
            return UpdateBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Imla \(version) is ready to install",
                message: "The update is downloaded. Use the menu bar updater to finish installation.",
                tint: ImlaTheme.transcribing
            )
        case .installing(let version):
            return UpdateBanner(
                icon: "arrow.down.circle.fill",
                title: "Installing Imla \(version)",
                message: "Sparkle is preparing the update. Imla may relaunch when installation finishes.",
                tint: ImlaTheme.transcribing
            )
        case .upToDate:
            return UpdateBanner(
                icon: "checkmark.circle.fill",
                title: "Imla is up to date",
                message: "No newer version was found in the appcast.",
                tint: ImlaTheme.success
            )
        case .disabled(let message):
            return UpdateBanner(
                icon: "minus.circle.fill",
                title: "Updates are disabled",
                message: message,
                tint: ImlaTheme.textTertiary
            )
        case .failed(let message):
            return UpdateBanner(
                icon: "xmark.octagon.fill",
                title: "Update check failed",
                message: "\(message) Use the menu bar icon > Check for Updates... to try again.",
                tint: ImlaTheme.danger
            )
        }
    }

    @ViewBuilder
    private func updateBannerView(_ banner: UpdateBanner) -> some View {
        HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
            Image(systemName: banner.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                Text(banner.title)
                    .font(ImlaTheme.headline())
                    .foregroundStyle(ImlaTheme.textPrimary)
                Text(banner.message)
                    .font(ImlaTheme.callout())
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: ImlaTheme.spacing16)
        }
        .padding(ImlaTheme.spacing16)
        .background(banner.tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(banner.tint.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func aboutRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(ImlaTheme.body())
                .foregroundStyle(ImlaTheme.textPrimary)
            Spacer()
            control()
        }
        .padding(.vertical, ImlaTheme.spacing8)
    }

    @ViewBuilder
    private func acknowledgement(name: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
            Text(name)
                .font(ImlaTheme.font(size: 14, weight: .semibold))
                .foregroundStyle(ImlaTheme.textPrimary)
            Text(description)
                .font(ImlaTheme.callout())
                .foregroundStyle(ImlaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ImlaTheme.spacing8)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(ImlaTheme.font(size: 13, weight: .medium))
            }
            .foregroundStyle(ImlaTheme.textPrimary)
            .padding(.horizontal, ImlaTheme.spacing16)
            .padding(.vertical, ImlaTheme.spacing8)
            .frame(width: actionButtonWidth)
            .background(ImlaTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
