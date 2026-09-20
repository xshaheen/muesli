import SwiftUI
import AppKit
import ImlaCore

struct ShortcutsView: View {
    let appState: AppState
    let controller: ImlaController
    @State private var permissionMonitoringClientID = UUID()
    @State private var recordingTarget: ShortcutTarget?
    @State private var eventMonitor: Any?
    @State private var pendingModifierKeyCode: UInt16?
    @State private var dictationShortcutMessage: String?
    @State private var computerUseShortcutMessage: String?
    @State private var quilShortcutMessage: String?
    @State private var meetingRecordingShortcutMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing24) {

                Text("Choose your preferred shortcuts for dictation and computer use commands.")
                    .font(ImlaTheme.body())
                    .foregroundStyle(ImlaTheme.textSecondary)

                dictationShortcutSection

                computerUseShortcutSection

                quilShortcutSection

                meetingRecordingShortcutSection

                doubleTapSection

                resetButton
            }
            .padding(.horizontal, ImlaTheme.pageHorizontalInset)
            .padding(.top, ImlaTheme.pageTop)
            .padding(.bottom, ImlaTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            controller.beginInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
            reconcilePushToTalkState()
            reconcileIndependentShortcutState()
        }
        .onChange(of: appState.interactionPermissionSnapshot) { _, snapshot in
            guard let snapshot else { return }
            reconcilePushToTalkState(permissions: snapshot.onboardingSnapshot)
            reconcileIndependentShortcutState()
        }
        .onDisappear {
            controller.endInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
            stopRecording()
        }
    }

    private var isPushToTalkEnabled: Bool {
        appState.config.enablePushToTalk
    }

    private var pushToTalkPermissionMessage: String {
        PushToTalkEnablementPolicy.PermissionProfile.resolved(
            for: appState.config.resolvedOnboardingUseCase
        ).missingPermissionsMessage
    }

    private enum ShortcutTarget {
        case dictation
        case computerUse
        case quil
        case meetingRecording
    }

    private var dictationShortcutSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    Text("Push to Talk")
                        .font(ImlaTheme.headline())
                        .foregroundStyle(ImlaTheme.textPrimary)
                    Text("Hold to record, release to transcribe")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: ImlaTheme.spacing8) {
                    Text(isPushToTalkEnabled ? "On" : "Off")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                    Toggle("Push to Talk", isOn: Binding(
                        get: { isPushToTalkEnabled },
                        set: updatePushToTalkEnabled
                    ))
                    .toggleStyle(.switch)
                    .tint(ImlaTheme.accent)
                    .labelsHidden()
                }
            }

            Divider()
                .background(ImlaTheme.surfaceBorder)

            pushToTalkControls

            if !isPushToTalkEnabled {
                pushToTalkDisabledMessage
            }

            if let dictationShortcutMessage {
                shortcutMessage(dictationShortcutMessage)
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var computerUseShortcutSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    Text("Computer Use Command")
                        .font(ImlaTheme.headline())
                        .foregroundStyle(ImlaTheme.textPrimary)
                    Text("Hold to record a command, release to plan and run it")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableComputerUseHotkey },
                    set: { newValue in
                        let result = controller.updateComputerUseHotkeyEnabled(newValue)
                        computerUseShortcutMessage = result.message
                        if result.didUpdate {
                            dictationShortcutMessage = nil
                        }
                    }
                ))
                .toggleStyle(.switch)
                .tint(ImlaTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(ImlaTheme.surfaceBorder)

            shortcutControls(
                target: .computerUse,
                threshold: appState.config.computerUseHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableComputerUseHotkey
            ) { value in
                controller.updateConfig { $0.computerUseHotkeyTriggerThresholdMS = value }
            }

            if appState.config.enableComputerUseHotkey,
               ShortcutHotkeyPolicy.hotkeysConflict(appState.config.computerUseHotkey, appState.config.dictationHotkey) {
                shortcutMessage(ShortcutHotkeyPolicy.conflictMessage)
            } else if let computerUseShortcutMessage {
                shortcutMessage(computerUseShortcutMessage)
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var meetingRecordingShortcutSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    Text("Meeting Recording")
                        .font(ImlaTheme.headline())
                        .foregroundStyle(ImlaTheme.textPrimary)
                    Text("Toggle meeting recording on/off")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableMeetingRecordingHotkey },
                    set: { newValue in
                        let result = controller.updateMeetingRecordingHotkeyEnabled(newValue)
                        meetingRecordingShortcutMessage = result.message
                    }
                ))
                .toggleStyle(.switch)
                .tint(ImlaTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(ImlaTheme.surfaceBorder)

            shortcutControls(
                target: .meetingRecording,
                threshold: appState.config.meetingRecordingHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableMeetingRecordingHotkey
            ) { value in
                controller.updateConfig { $0.meetingRecordingHotkeyTriggerThresholdMS = value }
            }

            if let meetingRecordingShortcutMessage {
                shortcutMessage(meetingRecordingShortcutMessage)
            } else if appState.config.enableMeetingRecordingHotkey,
                      let warning = ShortcutHotkeyPolicy.commonGlobalShortcutWarning(for: appState.config.meetingRecordingHotkey) {
                shortcutMessage(warning)
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var quilShortcutSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Image(nsImage: QuillIcon.image())
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(ImlaTheme.accent)
                        Text("Quill")
                            .font(ImlaTheme.headline())
                            .foregroundStyle(ImlaTheme.textPrimary)
                    }
                    Text("Highlight text, hold to speak an editing instruction, then release to replace")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableQuilMode },
                    set: { newValue in
                        let result = controller.updateQuilModeEnabled(newValue)
                        quilShortcutMessage = result.message
                    }
                ))
                .toggleStyle(.switch)
                .tint(ImlaTheme.accent)
                .labelsHidden()
            }

            Divider().background(ImlaTheme.surfaceBorder)

            shortcutControls(
                target: .quil,
                threshold: appState.config.quilHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableQuilMode
            ) { value in
                controller.updateConfig { $0.quilHotkeyTriggerThresholdMS = value }
            }

            if let quilShortcutMessage { shortcutMessage(quilShortcutMessage) }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func hotkeyBadge(_ hotkey: HotkeyConfig) -> some View {
        Text(hotkey.displayLabel)
            .font(ImlaTheme.font(size: 12, weight: .medium))
            .foregroundStyle(ImlaTheme.textPrimary)
            .padding(.horizontal, ImlaTheme.spacing12)
            .padding(.vertical, ImlaTheme.spacing4)
            .background(ImlaTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
            )
            .help(hotkey.label)
    }

    private func shortcutControls(
        target: ShortcutTarget,
        threshold: Int,
        isEnabled: Bool = true,
        onThresholdChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: ImlaTheme.spacing12) {
            hotkeyBadge(hotkey(for: target))
            compactChangeButton(for: target)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
            Spacer(minLength: ImlaTheme.spacing16)
            if isEnabled {
                thresholdInput(
                    value: threshold,
                    onChange: onThresholdChange
                )
            }
        }
    }

    private var pushToTalkControls: some View {
        HStack(spacing: ImlaTheme.spacing12) {
            Text("Shortcut")
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textSecondary)
            hotkeyBadge(appState.config.dictationHotkey)
            compactChangeButton(for: .dictation)
            Spacer(minLength: ImlaTheme.spacing16)
            thresholdInput(
                value: appState.config.hotkeyTriggerThresholdMS,
                label: "Hold duration"
            ) { value in
                controller.updateConfig { $0.hotkeyTriggerThresholdMS = value }
            }
        }
        .disabled(!isPushToTalkEnabled)
        .opacity(isPushToTalkEnabled ? 1 : 0.55)
    }

    private func hotkey(for target: ShortcutTarget) -> HotkeyConfig {
        switch target {
        case .dictation:
            return appState.config.dictationHotkey
        case .computerUse:
            return appState.config.computerUseHotkey
        case .quil:
            return appState.config.quilHotkey
        case .meetingRecording:
            return appState.config.meetingRecordingHotkey
        }
    }

    private func thresholdInput(
        value: Int,
        label: String = "Hold",
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: ImlaTheme.spacing8) {
            Text(label)
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textSecondary)

            TextField(
                "",
                value: Binding(
                    get: { HotkeyTriggerTiming.clampedMilliseconds(value) },
                    set: { onChange(HotkeyTriggerTiming.clampedMilliseconds($0)) }
                ),
                format: .number
            )
            .textFieldStyle(.plain)
            .font(ImlaTheme.mono(size: 13, weight: .semibold))
            .foregroundStyle(ImlaTheme.textPrimary)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .padding(.horizontal, ImlaTheme.spacing8)
            .padding(.vertical, ImlaTheme.spacing4)
            .background(ImlaTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
            )

            Text("ms")
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textSecondary)
        }
        .help("Hold threshold: \(HotkeyTriggerTiming.minThresholdMilliseconds)-\(HotkeyTriggerTiming.maxThresholdMilliseconds) ms")
    }

    private var pushToTalkDisabledMessage: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            Image(systemName: "info.circle")
                .foregroundStyle(ImlaTheme.accent)
            Text(pushToTalkDisabledMessageText)
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textSecondary)
        }
    }

    private var pushToTalkDisabledMessageText: String {
        appState.config.resolvedOnboardingUseCase.includesPushToTalk
            ? "Push to Talk is turned off."
            : "Dictation wasn’t enabled during setup."
    }

    private func shortcutMessage(_ message: String) -> some View {
        Text(message)
            .font(ImlaTheme.caption())
            .foregroundStyle(ImlaTheme.transcribing)
    }

    private func compactChangeButton(for target: ShortcutTarget) -> some View {
        Button {
            if recordingTarget == target {
                stopRecording()
            } else {
                startRecording(target)
            }
        } label: {
            Text(recordingTarget == target ? recordingPrompt(for: target) : "Change…")
                .font(ImlaTheme.body())
                .foregroundStyle(ImlaTheme.accent)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ImlaTheme.spacing12)
        .padding(.vertical, ImlaTheme.spacing8)
        .background(recordingTarget == target ? ImlaTheme.accentSubtle : ImlaTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                .strokeBorder(recordingTarget == target ? ImlaTheme.accent.opacity(0.3) : ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func updatePushToTalkEnabled(_ enabled: Bool) {
        if !enabled, recordingTarget == .dictation {
            stopRecording()
        }
        let result = controller.updatePushToTalkEnabled(enabled, requestPermissions: enabled)
        switch result {
        case .alreadyEnabled, .enabled, .disabled:
            dictationShortcutMessage = nil
        case .needsPermissions:
            dictationShortcutMessage = pushToTalkPermissionMessage
        }
    }

    private func reconcilePushToTalkState(
        permissions: OnboardingPermissionSnapshot? = nil
    ) {
        if let result = controller.reconcilePendingPushToTalkEnableIfReady(permissions: permissions) {
            switch result {
            case .alreadyEnabled, .enabled, .disabled:
                dictationShortcutMessage = nil
            case .needsPermissions:
                dictationShortcutMessage = pushToTalkPermissionMessage
            }
            return
        }

        guard isPushToTalkEnabled, let permissions else { return }
        let profile = PushToTalkEnablementPolicy.PermissionProfile.resolved(
            for: appState.config.resolvedOnboardingUseCase
        )
        if profile.hasRequiredPermissions(permissions) {
            if dictationShortcutMessage == profile.missingPermissionsMessage {
                dictationShortcutMessage = nil
            }
        } else if dictationShortcutMessage == nil
                    || dictationShortcutMessage == profile.missingPermissionsMessage {
            dictationShortcutMessage = profile.missingPermissionsMessage
        }
    }

    private func reconcileIndependentShortcutState() {
        let permissionMessage = ShortcutFeatureEnablementPolicy.missingPermissionsMessage
        let computerUsePermissionMessage = controller.independentShortcutPermissionMessageIfNeeded(
            isEnabled: appState.config.enableComputerUseHotkey
        )
        if let computerUsePermissionMessage {
            computerUseShortcutMessage = computerUsePermissionMessage
        } else if computerUseShortcutMessage == permissionMessage {
            computerUseShortcutMessage = nil
        }

        let quilPermissionMessage = controller.independentShortcutPermissionMessageIfNeeded(
            isEnabled: appState.config.enableQuilMode
        )
        if let quilPermissionMessage {
            quilShortcutMessage = quilPermissionMessage
        } else if quilShortcutMessage == permissionMessage {
            quilShortcutMessage = nil
        }
    }

    private func recordingPrompt(for target: ShortcutTarget) -> String {
        switch target {
        case .meetingRecording:
            return "Press a key or modifier..."
        case .quil:
            return "Press one key or a two-key shortcut..."
        case .dictation, .computerUse:
            return "Press a modifier key..."
        }
    }

    private var doubleTapSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    Text("Hands-Free Mode")
                        .font(ImlaTheme.headline())
                        .foregroundStyle(ImlaTheme.textPrimary)
                    Text("Double-tap dictation, Quill, or CUA to start; tap again to stop")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableDoubleTapDictation },
                    set: { newValue in
                        controller.updateConfig { $0.enableDoubleTapDictation = newValue }
                    }
                ))
                .toggleStyle(.switch)
                .tint(ImlaTheme.accent)
                .labelsHidden()
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var resetButton: some View {
        Button {
            controller.resetShortcutDefaults()
            dictationShortcutMessage = nil
            computerUseShortcutMessage = nil
            meetingRecordingShortcutMessage = nil
            quilShortcutMessage = nil
        } label: {
            Text("Reset to Defaults")
                .font(ImlaTheme.body())
                .foregroundStyle(ImlaTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(
            appState.config.dictationHotkey == .default
                && appState.config.computerUseHotkey == .computerUseDefault
                && !appState.config.enableComputerUseHotkey
                && appState.config.quilHotkey == .quilDefault
                && !appState.config.enableQuilMode
                && appState.config.meetingRecordingHotkey == .meetingRecordingDefault
                && !appState.config.enableMeetingRecordingHotkey
                && appState.config.hotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds
                && appState.config.computerUseHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds
                && appState.config.quilHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds
                && appState.config.meetingRecordingHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds
        )
    }

    private func startRecording(_ target: ShortcutTarget) {
        stopRecording()
        clearShortcutMessage(for: target)
        pendingModifierKeyCode = nil
        recordingTarget = target
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                let mods = HotkeyConfig.supportedCombinationModifiers(from: event.modifierFlags)
                let modifierCount = [NSEvent.ModifierFlags.command, .control, .option, .shift]
                    .filter { mods.contains($0) }.count
                let allowsCombination = target == .meetingRecording || target == .quil
                guard allowsCombination,
                      (target != .quil || modifierCount == 1),
                      modifierCount > 0,
                      HotkeyConfig.letterLabel(for: event.keyCode) != nil else {
                    return event
                }
                pendingModifierKeyCode = nil
                let newConfig = HotkeyConfig.combination(modifiers: mods, keyCode: event.keyCode)
                commitShortcut(newConfig, for: target)
                return nil
            }

            let keyCode = event.keyCode
            guard HotkeyConfig.label(for: keyCode) != nil else { return event }
            let flags = event.modifierFlags
            let isDown: Bool
            switch keyCode {
            case 55, 54: isDown = flags.contains(.command)
            case 56, 60: isDown = flags.contains(.shift)
            case 58, 61: isDown = flags.contains(.option)
            case 59, 62: isDown = flags.contains(.control)
            case 63: isDown = flags.contains(.function)
            default: isDown = false
            }
            if isDown {
                pendingModifierKeyCode = keyCode
            } else if keyCode == pendingModifierKeyCode {
                let newConfig = HotkeyConfig(keyCode: keyCode, label: HotkeyConfig.label(for: keyCode)!)
                pendingModifierKeyCode = nil
                commitShortcut(newConfig, for: target)
            }
            return event
        }
    }

    private func commitShortcut(_ config: HotkeyConfig, for target: ShortcutTarget) {
        let result: ShortcutHotkeyUpdateResult
        switch target {
        case .dictation:
            result = controller.updateDictationHotkey(config)
        case .computerUse:
            result = controller.updateComputerUseHotkey(config)
        case .quil:
            result = controller.updateQuilHotkey(config)
        case .meetingRecording:
            result = controller.updateMeetingRecordingHotkey(config)
        }
        setShortcutMessage(result.message, for: target)
        stopRecording()
    }

    private func clearShortcutMessage(for target: ShortcutTarget) {
        setShortcutMessage(nil, for: target)
    }

    private func setShortcutMessage(_ message: String?, for target: ShortcutTarget) {
        switch target {
        case .dictation:
            dictationShortcutMessage = message
            if message == nil { computerUseShortcutMessage = nil; meetingRecordingShortcutMessage = nil; quilShortcutMessage = nil }
        case .computerUse:
            computerUseShortcutMessage = message
            if message == nil { dictationShortcutMessage = nil; meetingRecordingShortcutMessage = nil; quilShortcutMessage = nil }
        case .quil:
            quilShortcutMessage = message
            if message == nil { dictationShortcutMessage = nil; computerUseShortcutMessage = nil; meetingRecordingShortcutMessage = nil }
        case .meetingRecording:
            meetingRecordingShortcutMessage = message
            if message == nil { dictationShortcutMessage = nil; computerUseShortcutMessage = nil; quilShortcutMessage = nil }
        }
    }

    private func stopRecording() {
        recordingTarget = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
